# frozen_string_literal: true

require 'yaml'

module CgminerMonitor
  class Poller
    COMMANDS = %w[summary devs pools stats].freeze

    attr_reader :polls_ok, :polls_failed

    def initialize(config, miner_pool: nil, alert_evaluator: nil)
      @config          = config
      @miner_pool      = miner_pool || build_miner_pool(config.miners_file)
      @alert_evaluator = alert_evaluator || AlertEvaluator.new(config)
      @stopped         = false
      @mutex           = Mutex.new
      @cv              = ConditionVariable.new
      @polls_ok        = 0
      @polls_failed    = 0
    end

    def poll_once
      # Capture @miner_pool once so a mid-poll reload! (which atomically
      # swaps the ivar) can't mix miner_ids from the old list with query
      # results from the new pool. Threading `pool` through poll_miner /
      # query_command keeps the whole tick consistent.
      pool         = @miner_pool
      now          = Time.now.utc
      all_samples  = []
      snapshot_ops = []

      pool.miners.each do |miner|
        poll_miner(pool, miner, now, all_samples, snapshot_ops)
      end

      write_samples(all_samples) unless all_samples.empty?
      write_snapshots(snapshot_ops) unless snapshot_ops.empty?

      Logger.info(event: 'poll.complete',
                  samples_written: all_samples.size,
                  snapshots_upserted: snapshot_ops.size,
                  polls_ok: @polls_ok,
                  polls_failed: @polls_failed)

      # Evaluator runs AFTER the samples + snapshots are persisted so
      # it always reads the just-written state (the offline rule keys
      # on the poll/ok=1.0 sample this tick just wrote). Also runs
      # after the poll.complete log so the fleet-level "poll finished"
      # event isn't interleaved with per-miner alert emissions.
      # Evaluator emits its own alert.evaluation_complete for
      # end-to-end timing.
      run_alert_evaluator(now)
    rescue Mongo::Error => e
      increment_failed
      Logger.error(event: 'mongo.write_failed', error: e.class.to_s, message: e.message)
    rescue StandardError => e
      increment_failed
      Logger.error(event: 'poll.unexpected_error', error: e.class.to_s,
                   message: e.message, backtrace: e.backtrace&.first(10))
    end

    def run_until_stopped(_stop_channel)
      until @stopped
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        poll_once
        elapsed   = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        remaining = @config.interval - elapsed
        interruptible_sleep(remaining) if remaining.positive?
      end
    end

    def stop
      @mutex.synchronize do
        @stopped = true
        @cv.signal
      end
    end

    def stopped?
      @stopped
    end

    # Rebuilds @miner_pool from `miners_file` by constructing a *new*
    # MinerPool and swapping the ivar. Never mutates an existing pool's
    # miners array in place — any in-flight poll_once has already
    # captured the old pool as a local and would see a torn read if we
    # mutated. MRI's GVL makes the `@miner_pool =` assignment atomic.
    # Returns the new miner count on success, nil on parse/IO failure
    # (old pool is untouched on failure). The rescue list covers only
    # named validation/IO failures from build_miner_pool — a bug like
    # a method rename surfaces as an uncaught NoMethodError, which is
    # what we want; don't broaden the rescue.
    def reload!(miners_file = @config.miners_file)
      new_pool = build_miner_pool(miners_file)
      @miner_pool = new_pool
      new_pool.miners.size
    rescue CgminerMonitor::ConfigError, Errno::ENOENT, Psych::SyntaxError => e
      Logger.warn(event: 'reload.failed',
                  error: e.class.to_s, message: e.message)
      nil
    end

    private

    def run_alert_evaluator(now)
      @alert_evaluator.evaluate(now)
    rescue StandardError => e
      Logger.error(event: 'alert.evaluator_error', error: e.class.to_s,
                   message: e.message, backtrace: e.backtrace&.first(10))
    end

    def poll_miner(pool, miner, now, all_samples, snapshot_ops)
      miner_id   = "#{miner.host}:#{miner.port}"
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      miner_ok   = true

      COMMANDS.each do |command|
        pool_result  = pool.query(command)
        miner_result = pool_result[miner_id]

        if miner_result&.ok?
          process_success(miner_id, command, miner_result, now, all_samples, snapshot_ops)
        else
          miner_ok = false
          process_failure(miner_id, command, miner_result, now, snapshot_ops)
        end
      end

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      append_synthetic_samples(miner_id, miner_ok, elapsed_ms, now, all_samples)
      miner_ok ? increment_ok : increment_failed
    end

    def increment_ok
      @mutex.synchronize { @polls_ok += 1 }
    end

    def increment_failed
      @mutex.synchronize { @polls_failed += 1 }
    end

    def process_success(miner_id, command, miner_result, now, all_samples, snapshot_ops)
      response = miner_result.value.is_a?(Array) ? miner_result.value.first : miner_result.value
      all_samples.concat(extract_samples(miner_id, command, response, now))
      snapshot_ops << build_snapshot_upsert(
        miner_id, command,
        { "fetched_at" => now, "ok" => true, "response" => response, "error" => nil }
      )
    end

    def process_failure(miner_id, command, miner_result, now, snapshot_ops)
      error_msg = miner_result ? "#{miner_result.error.class}: #{miner_result.error.message}" : 'no result'
      snapshot_ops << build_snapshot_upsert(
        miner_id, command,
        { "fetched_at" => now, "ok" => false, "response" => nil, "error" => error_msg }
      )
      Logger.warn(event: 'poll.miner_failed', miner: miner_id, command: command, error: error_msg)
    end

    def append_synthetic_samples(miner_id, miner_ok, elapsed_ms, now, all_samples)
      all_samples << sample_hash(miner_id, 'poll', 0, 'ok', miner_ok ? 1.0 : 0.0, now)
      all_samples << sample_hash(miner_id, 'poll', 0, 'duration_ms', elapsed_ms, now)
    end

    def extract_samples(miner_id, command, response, ts)
      rows        = []
      command_key = command.upcase
      entries     = response&.dig(command_key)
      return rows unless entries.is_a?(Array)

      entries.each_with_index do |entry, sub|
        next unless entry.is_a?(Hash)

        entry.each do |field, value|
          numeric_value = to_numeric(value)
          next unless numeric_value

          rows << sample_hash(miner_id, command, sub, normalize_metric(field), numeric_value, ts)
        end
      end

      rows
    end

    # Only numeric values become samples. Booleans, nil, hashes, and
    # non-numeric strings (device status, pool URL, worker name, etc.)
    # return nil here and are silently skipped by extract_samples.
    # The full response is still preserved in latest_snapshot, so no
    # data is lost — just not duplicated into the time-series store.
    def to_numeric(value)
      case value
      when Integer, Float then value.to_f
      when String         then Float(value, exception: false)
      end
    end

    def normalize_metric(field)
      field.to_s.downcase.tr(' ', '_').gsub('%', '_pct')
    end

    def sample_hash(miner_id, command, sub, metric, value, ts)
      {
        ts: ts,
        meta: { "miner" => miner_id, "command" => command, "sub" => sub, "metric" => metric },
        v: value.to_f
      }
    end

    def build_snapshot_upsert(miner_id, command, attrs)
      {
        update_one: {
          filter: { "miner" => miner_id, "command" => command },
          update: { "$set" => attrs },
          upsert: true
        }
      }
    end

    def write_samples(samples)
      Sample.collection.insert_many(samples)
    end

    def write_snapshots(ops)
      Snapshot.collection.bulk_write(ops, ordered: false)
    end

    def build_miner_pool(miners_file)
      # CgminerApiClient::MinerPool.new hardcodes 'config/miners.yml' relative
      # to CWD via load_miners!. We bypass initialize with allocate and set
      # miners directly from the configurable miners_file path.
      miners_config = YAML.safe_load_file(miners_file)
      unless miners_config.is_a?(Array) && miners_config.all? { |m| m.is_a?(Hash) && m['host'] }
        raise CgminerMonitor::ConfigError,
              "#{miners_file} must be a YAML list of {host, port} entries"
      end

      pool          = CgminerApiClient::MinerPool.allocate
      pool.miners   = miners_config.collect do |miner|
        CgminerApiClient::Miner.new(miner['host'], miner['port'], miner['timeout'])
      end
      pool
    rescue Errno::ENOENT
      raise CgminerMonitor::ConfigError, "miners_file not found: #{miners_file}"
    end

    def interruptible_sleep(seconds)
      @mutex.synchronize do
        @cv.wait(@mutex, seconds) unless @stopped
      end
    end
  end
end
