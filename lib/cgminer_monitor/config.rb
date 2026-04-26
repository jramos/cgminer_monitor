# frozen_string_literal: true

require 'uri'

module CgminerMonitor
  Config = Data.define(
    :interval,
    :retention_seconds,
    :mongo_url,
    :http_host, :http_port, :http_min_threads, :http_max_threads,
    :miners_file,
    :log_format, :log_level,
    :cors_origins,
    :shutdown_timeout,
    :healthz_stale_multiplier,
    :healthz_startup_grace_seconds,
    :pid_file,
    :alerts_enabled,
    :alerts_webhook_url,
    :alerts_webhook_format,
    :alerts_hashrate_min_ghs,
    :alerts_temperature_max_c,
    :alerts_offline_after_seconds,
    :alerts_cooldown_seconds,
    :alerts_webhook_timeout_seconds,
    :composite_rules,
    :restart_schedule_url,
    :restart_window_grace_seconds
  ) do
    def validate!
      raise ConfigError, "interval must be > 0" unless interval.positive?
      raise ConfigError, "log_format must be json or text" unless %w[json text].include?(log_format)
      raise ConfigError, "miners_file not found: #{miners_file}" unless File.exist?(miners_file)
      raise ConfigError, "invalid log_level" unless %w[debug info warn error].include?(log_level)

      validate_alerts! if alerts_enabled
      validate_restart_window!

      self
    end

    def public_attrs
      to_h.merge(mongo_url: redact_mongo_url(mongo_url))
    end

    private

    def validate_alerts!
      raise ConfigError, "alerts_webhook_url is required when alerts_enabled=true" if alerts_webhook_url.nil?

      uri = begin
        URI.parse(alerts_webhook_url)
      rescue URI::InvalidURIError
        raise ConfigError, "alerts_webhook_url is not a valid URL: #{alerts_webhook_url.inspect}"
      end
      raise ConfigError, "alerts_webhook_url scheme must be http or https" unless %w[http https].include?(uri.scheme)
      # URI.parse('http:/') is a successful parse but yields a URI with no
      # host — Net::HTTP.start(nil, nil, ...) would raise ArgumentError at
      # first fire, deferring the bad-config signal from boot to whenever
      # the first alert tries to emit. Fail at boot instead.
      raise ConfigError, "alerts_webhook_url must include a host" if uri.host.to_s.empty?

      unless %w[generic slack discord].include?(alerts_webhook_format)
        raise ConfigError,
              "alerts_webhook_format must be one of generic, slack, discord"
      end

      raise ConfigError, "alerts_cooldown_seconds must be > 0" unless alerts_cooldown_seconds.positive?
      raise ConfigError, "alerts_webhook_timeout_seconds must be > 0" unless alerts_webhook_timeout_seconds.positive?

      return if alerts_hashrate_min_ghs || alerts_temperature_max_c ||
                alerts_offline_after_seconds || composite_rules.any?

      raise ConfigError,
            "alerts_enabled=true but no rule configured " \
            "(set at least one of CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS / " \
            "CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C / " \
            "CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS, " \
            "or define a composite via CGMINER_MONITOR_ALERTS_COMPOSITE_*)"
    end

    def redact_mongo_url(url)
      url.to_s.sub(%r{://[^@]+@}, "://[REDACTED]@")
    end

    def validate_restart_window!
      return if restart_schedule_url.nil?

      uri = begin
        URI.parse(restart_schedule_url)
      rescue URI::InvalidURIError
        raise ConfigError, "restart_schedule_url is not a valid URL: #{restart_schedule_url.inspect}"
      end
      raise ConfigError, "restart_schedule_url scheme must be http or https" unless %w[http https].include?(uri.scheme)
      raise ConfigError, "restart_schedule_url must include a host" if uri.host.to_s.empty?
      raise ConfigError, "restart_window_grace_seconds must be > 0" unless restart_window_grace_seconds.positive?
    end
  end

  class << Config
    def from_env(env = ENV)
      new(
        interval: parse_int(env, "CGMINER_MONITOR_INTERVAL", "60"),
        retention_seconds: parse_int(env, "CGMINER_MONITOR_RETENTION_SECONDS", (30 * 86_400).to_s),
        mongo_url: env.fetch("CGMINER_MONITOR_MONGO_URL",
                             "mongodb://localhost:27017/cgminer_monitor"),
        http_host: env.fetch("CGMINER_MONITOR_HTTP_HOST", "127.0.0.1"),
        http_port: parse_int(env, "CGMINER_MONITOR_HTTP_PORT", "9292"),
        http_min_threads: parse_int(env, "CGMINER_MONITOR_HTTP_MIN_THREADS", "1"),
        http_max_threads: parse_int(env, "CGMINER_MONITOR_HTTP_MAX_THREADS", "5"),
        miners_file: env.fetch("CGMINER_MONITOR_MINERS_FILE", "config/miners.yml"),
        log_format: env.fetch("CGMINER_MONITOR_LOG_FORMAT", "json"),
        log_level: env.fetch("CGMINER_MONITOR_LOG_LEVEL", "info"),
        cors_origins: env.fetch("CGMINER_MONITOR_CORS_ORIGINS", "*"),
        shutdown_timeout: parse_int(env, "CGMINER_MONITOR_SHUTDOWN_TIMEOUT", "10"),
        healthz_stale_multiplier: parse_int(env, "CGMINER_MONITOR_HEALTHZ_STALE_MULTIPLIER", "2"),
        healthz_startup_grace_seconds: parse_int(env, "CGMINER_MONITOR_HEALTHZ_STARTUP_GRACE", "60"),
        pid_file: env["CGMINER_MONITOR_PID_FILE"],
        alerts_enabled: parse_bool(env, "CGMINER_MONITOR_ALERTS_ENABLED", "false"),
        alerts_webhook_url: env["CGMINER_MONITOR_ALERTS_WEBHOOK_URL"],
        alerts_webhook_format: env.fetch("CGMINER_MONITOR_ALERTS_WEBHOOK_FORMAT", "generic"),
        alerts_hashrate_min_ghs: parse_optional_float(env, "CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS"),
        alerts_temperature_max_c: parse_optional_float(env, "CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C"),
        alerts_offline_after_seconds: parse_optional_int(env, "CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS"),
        alerts_cooldown_seconds: parse_int(env, "CGMINER_MONITOR_ALERTS_COOLDOWN_SECONDS", "300"),
        alerts_webhook_timeout_seconds: parse_int(env, "CGMINER_MONITOR_ALERTS_WEBHOOK_TIMEOUT_SECONDS", "2"),
        composite_rules: parse_composite_rules(env),
        restart_schedule_url: env["CGMINER_MONITOR_RESTART_SCHEDULE_URL"],
        restart_window_grace_seconds: parse_int(env, "CGMINER_MONITOR_RESTART_WINDOW_GRACE_SECONDS", "300")
      ).validate!
    end

    def current
      @current ||= from_env
    end

    def reset!
      @current = nil
    end

    TRUE_VALUES  = %w[1 true yes on].freeze
    FALSE_VALUES = %w[0 false no off].freeze
    private_constant :TRUE_VALUES, :FALSE_VALUES

    private

    def parse_int(env, key, default)
      Integer(env.fetch(key, default))
    rescue ArgumentError
      raise ConfigError, "#{key} must be a valid integer, got: #{env[key].inspect}"
    end

    def parse_bool(env, key, default)
      raw = env.fetch(key, default).to_s.downcase
      return true  if TRUE_VALUES.include?(raw)
      return false if FALSE_VALUES.include?(raw)

      raise ConfigError, "#{key} must be a boolean (1/0/true/false/yes/no/on/off), got: #{env[key].inspect}"
    end

    # An env key that is *set but empty* (`export FOO=`) is operator
    # intent expressed ambiguously — did they mean to unset it and
    # typo, or did they mean the rule should be disabled? We refuse
    # both interpretations and fail loud. Matches the project's
    # fail-fast-on-config posture over the Float(..., exception: false)
    # silent-disable behavior.
    def parse_optional_float(env, key)
      return nil unless env.key?(key)
      raise ConfigError, "#{key} is set but empty" if env[key].to_s.empty?

      Float(env[key])
    rescue ArgumentError, TypeError
      raise ConfigError, "#{key} must be a valid float, got: #{env[key].inspect}"
    end

    def parse_optional_int(env, key)
      return nil unless env.key?(key)
      raise ConfigError, "#{key} is set but empty" if env[key].to_s.empty?

      Integer(env[key])
    rescue ArgumentError, TypeError
      raise ConfigError, "#{key} must be a valid integer, got: #{env[key].inspect}"
    end

    COMPOSITE_PREFIX = "CGMINER_MONITOR_ALERTS_COMPOSITE_"
    private_constant :COMPOSITE_PREFIX

    # Discovers composite rule ENV vars by prefix scan, then routes
    # each through CompositeRuleParser. Suffix becomes the lowercased
    # rule name (e.g. *_THERMAL_STRESS → "thermal_stress"). Parser
    # errors are re-raised with the originating ENV var name prefixed
    # so the operator sees which composite is broken without grepping.
    def parse_composite_rules(env)
      env.keys.grep(/\A#{Regexp.escape(COMPOSITE_PREFIX)}(.+)\z/).sort.map do |key|
        suffix = key.sub(/\A#{Regexp.escape(COMPOSITE_PREFIX)}/, '')
        name   = suffix.downcase
        expr   = env[key].to_s

        begin
          CompositeRuleParser.parse(name, expr)
        rescue ConfigError => e
          raise ConfigError, "#{key}: #{e.message.sub(/\Acomposite rule `[^`]+`: /, '')}"
        end
      end
    end
  end
end
