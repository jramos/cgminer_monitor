# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module CgminerMonitor
  # Polls cgminer_manager's GET /api/v1/restart_schedules.json (one HTTP
  # round-trip, parsed JSON cached for cache_seconds) and answers
  # in_restart_window?(miner, now) so AlertEvaluator can suppress the
  # `offline` rule while a miner is intentionally restarting.
  #
  # Fail-open by design: any fetch error (timeout, refused, malformed
  # JSON, unexpected schema) yields an empty schedule map and a single
  # restart.schedule_fetch_failed log per failure — monitor still emits
  # `offline` alerts on real outages even when the manager is down.
  class RestartScheduleClient
    DEFAULT_CACHE_SECONDS = 30

    def initialize(url:, grace_seconds:, cache_seconds: DEFAULT_CACHE_SECONDS, timeout: 2)
      @url           = url
      @grace_seconds = grace_seconds
      @cache_seconds = cache_seconds
      @timeout       = timeout
      @mutex         = Mutex.new
      @cached_at     = nil
      @cached_map    = {}
    end

    # Returns true iff the miner has an enabled schedule and `now` falls
    # in [scheduled_minute, scheduled_minute + grace_seconds) on the UTC
    # second-of-day axis (modulo 86_400 to handle midnight wrap).
    def in_restart_window?(miner, now)
      schedule = fetch[miner]
      return false if schedule.nil?
      return false unless schedule['enabled']

      time_utc = schedule['time_utc']
      return false unless time_utc.is_a?(String) && time_utc.match?(/\A\d{2}:\d{2}\z/)

      hh, mm    = time_utc.split(':').map(&:to_i)
      now_sod   = (now.utc.hour * 3600) + (now.utc.min * 60) + now.utc.sec
      start_sod = (hh * 3600) + (mm * 60)
      ((now_sod - start_sod) % 86_400) < @grace_seconds
    end

    # Returns true iff the miner is currently drained per the manager's
    # per-miner record (cgminer_manager v1.8.0+ Drain mode). Drain state
    # is consumed verbatim from the schedule entry — auto-resume timeouts
    # are enforced on the manager side, so monitor just reports what the
    # manager last published. `now` is unused but accepted for API
    # symmetry with `in_restart_window?` and to leave room for future
    # drain-window semantics.
    #
    # Defensive on every field: `drained` must be exactly `true` (not
    # truthy — a stray string would oscillate suppression on transient
    # malformed entries); `drained_at` must be a parseable ISO8601
    # string. Either failing returns false (fail-open, same posture as
    # the restart-window check).
    def in_drain?(miner, _now)
      schedule = fetch[miner]
      return false if schedule.nil?
      return false unless schedule['drained'] == true

      drained_at = schedule['drained_at']
      return false unless drained_at.is_a?(String)

      Time.iso8601(drained_at)
      true
    rescue ArgumentError
      false
    end

    private

    def fetch
      @mutex.synchronize do
        return @cached_map if @cached_at && (monotonic - @cached_at) < @cache_seconds

        @cached_map = fetch_uncached || @cached_map # keep stale on failure rather than oscillate
        @cached_at  = monotonic
        @cached_map
      end
    end

    def fetch_uncached
      uri = URI.parse(@url)
      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 open_timeout: @timeout,
                                 read_timeout: @timeout) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri))
      end

      return log_failure(:http_error, "status=#{response.code}") unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      build_map(parsed)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, IOError => e
      log_failure(e.class.to_s, e.message)
    rescue JSON::ParserError => e
      log_failure('JSON::ParserError', e.message)
    end

    def build_map(parsed)
      list = parsed.is_a?(Hash) ? parsed['schedules'] : nil
      return log_failure(:malformed, 'schedules key missing or not an array') unless list.is_a?(Array)

      list.each_with_object({}) do |entry, acc|
        next unless entry.is_a?(Hash) && entry['miner_id'].is_a?(String)

        acc[entry['miner_id']] = entry
      end
    end

    def log_failure(error, message)
      Logger.warn(event: 'restart.schedule_fetch_failed',
                  url: @url, error: error.to_s, message: message.to_s)
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
