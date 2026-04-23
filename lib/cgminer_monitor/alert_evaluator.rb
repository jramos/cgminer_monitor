# frozen_string_literal: true

module CgminerMonitor
  # Runs once per poll tick (from Poller#poll_once, after poll.complete).
  # Reads the just-written Snapshot collection, evaluates threshold rules
  # per miner, transitions alert_states, and dispatches the webhook
  # through the injected client. Disabled path is a single early return
  # so production behavior is unchanged when alerts_enabled=false.
  class AlertEvaluator
    RULES = %w[hashrate_below temperature_above offline].freeze
    UNITS = { 'hashrate_below' => 'GH/s',
              'temperature_above' => 'C',
              'offline' => 'seconds' }.freeze

    def initialize(config, webhook_client: nil)
      @config         = config
      @webhook_client = webhook_client
    end

    def evaluate(now)
      return unless @config.alerts_enabled

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      counts     = { fired: 0, resolved: 0, rules_evaluated: 0 }

      miner_states(now).each do |miner, rule_readings|
        rule_readings.each do |rule, observed|
          next if observed.nil? # rule disabled or data unavailable

          counts[:rules_evaluated] += 1
          evaluate_rule(miner: miner, rule: rule, observed: observed, now: now, counts: counts)
        end
      end

      Logger.info(event: 'alert.evaluation_complete',
                  duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1),
                  rules_evaluated: counts[:rules_evaluated],
                  fired_count: counts[:fired],
                  resolved_count: counts[:resolved])
    end

    private

    def evaluate_rule(miner:, rule:, observed:, now:, counts:)
      threshold = threshold_for(rule)
      return if threshold.nil?

      violating = violates?(rule, observed, threshold)
      state_doc = AlertState.where(_id: "#{miner}|#{rule}").first

      if violating
        handle_violating(miner: miner, rule: rule, observed: observed,
                         threshold: threshold, state_doc: state_doc, now: now, counts: counts)
      elsif state_doc&.state == 'violating'
        handle_resolved(miner: miner, rule: rule, observed: observed,
                        threshold: threshold, state_doc: state_doc, now: now, counts: counts)
      else
        ensure_ok_state(miner: miner, rule: rule, observed: observed,
                        threshold: threshold, state_doc: state_doc, now: now)
      end
    end

    def handle_violating(miner:, rule:, observed:, threshold:, state_doc:, now:, counts:)
      was_violating = state_doc&.state == 'violating'
      cooldown_elapsed = was_violating && state_doc.last_fired_at &&
                         (now - state_doc.last_fired_at) >= @config.alerts_cooldown_seconds
      fire = !was_violating || cooldown_elapsed

      upsert_state(miner: miner, rule: rule, observed: observed, threshold: threshold,
                   state: 'violating',
                   last_fired_at: fire ? now : state_doc&.last_fired_at,
                   last_transition_at: was_violating ? state_doc.last_transition_at : now)

      return unless fire

      counts[:fired] += 1
      emit(event: 'alert.fired', level: :warn,
           miner: miner, rule: rule, observed: observed, threshold: threshold, now: now)
    end

    def handle_resolved(miner:, rule:, observed:, threshold:, state_doc:, now:, counts:)
      upsert_state(miner: miner, rule: rule, observed: observed, threshold: threshold,
                   state: 'ok',
                   last_fired_at: state_doc&.last_fired_at,
                   last_transition_at: now)
      counts[:resolved] += 1
      emit(event: 'alert.resolved', level: :info,
           miner: miner, rule: rule, observed: observed, threshold: threshold, now: now)
    end

    def ensure_ok_state(miner:, rule:, observed:, threshold:, state_doc:, now:)
      return if state_doc&.state == 'ok' # no-op; avoid a Mongo write per tick

      upsert_state(miner: miner, rule: rule, observed: observed, threshold: threshold,
                   state: 'ok',
                   last_fired_at: nil,
                   last_transition_at: now)
    end

    def upsert_state(miner:, rule:, observed:, threshold:, state:,
                     last_fired_at:, last_transition_at:)
      doc = AlertState.find_or_initialize_by(_id: "#{miner}|#{rule}")
      doc.assign_attributes(miner: miner, rule: rule, state: state,
                            threshold: threshold, last_observed: observed,
                            last_fired_at: last_fired_at,
                            last_transition_at: last_transition_at)
      doc.save!
    rescue Mongo::Error, Mongoid::Errors::MongoidError => e
      Logger.error(event: 'alert.state_write_failed', miner: miner, rule: rule,
                   error: e.class.to_s, message: e.message)
    end

    def emit(event:, level:, miner:, rule:, observed:, threshold:, now:)
      Logger.public_send(level, event: event, miner: miner, rule: rule,
                                threshold: threshold, observed: observed, unit: UNITS[rule])
      return unless @webhook_client

      @webhook_client.fire(event: event, miner: miner, rule: rule,
                           threshold: threshold, observed: observed,
                           unit: UNITS[rule], fired_at: now)
    end

    def threshold_for(rule)
      case rule
      when 'hashrate_below'    then @config.alerts_hashrate_min_ghs
      when 'temperature_above' then @config.alerts_temperature_max_c
      when 'offline'           then @config.alerts_offline_after_seconds
      end
    end

    def violates?(rule, observed, threshold)
      case rule
      when 'hashrate_below'    then observed < threshold
      when 'temperature_above' then observed > threshold
      when 'offline'           then observed >= threshold
      end
    end

    # Returns {miner_id => {'hashrate_below' => val, 'temperature_above' => val, 'offline' => val}}.
    # Each reading is nil when the rule is disabled or the data isn't available.
    def miner_states(now)
      readings = Hash.new { |h, k| h[k] = { 'hashrate_below' => nil, 'temperature_above' => nil, 'offline' => nil } }

      if @config.alerts_hashrate_min_ghs
        Snapshot.where(command: 'summary', ok: true).each do |snap|
          readings[snap.miner]['hashrate_below'] = extract_hashrate(snap)
        end
      end

      if @config.alerts_temperature_max_c
        Snapshot.where(command: 'devs', ok: true).each do |snap|
          readings[snap.miner]['temperature_above'] = extract_temperature(snap)
        end
      end

      if @config.alerts_offline_after_seconds
        SnapshotQuery.miners.each do |entry|
          seconds_since = if entry[:ok] then 0.0
                          else (now - entry[:fetched_at]).to_f
                          end
          readings[entry[:miner]]['offline'] = seconds_since
        end
      end

      readings
    end

    def extract_hashrate(snapshot)
      summary = snapshot.response&.dig('SUMMARY')
      entry = summary.is_a?(Array) ? summary.first : nil
      raw = entry && (entry['GHS 5s'] || entry['ghs_5s'])
      return nil if raw.nil?

      Float(raw, exception: false)
    end

    def extract_temperature(snapshot)
      devices = snapshot.response&.dig('DEVS') || []
      temps = devices.map { |d| d['Temperature'] || d['temperature'] }
                     .map { |t| Float(t, exception: false) }
                     .compact
      return nil if temps.empty?

      temps.max
    end
  end
end
