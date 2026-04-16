# frozen_string_literal: true

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
    :healthz_startup_grace_seconds
  ) do
    def validate!
      raise ConfigError, "interval must be > 0" unless interval.positive?
      raise ConfigError, "log_format must be json or text" unless %w[json text].include?(log_format)
      raise ConfigError, "miners_file not found: #{miners_file}" unless File.exist?(miners_file)
      raise ConfigError, "invalid log_level" unless %w[debug info warn error].include?(log_level)

      self
    end

    def public_attrs
      to_h.merge(mongo_url: redact_mongo_url(mongo_url))
    end

    private

    def redact_mongo_url(url)
      url.to_s.sub(%r{://[^@]+@}, "://[REDACTED]@")
    end
  end

  class << Config
    def from_env(env = ENV)
      new(
        interval: Integer(env.fetch("CGMINER_MONITOR_INTERVAL", "60")),
        retention_seconds: Integer(env.fetch("CGMINER_MONITOR_RETENTION_SECONDS", (30 * 86_400).to_s)),
        mongo_url: env.fetch("CGMINER_MONITOR_MONGO_URL",
                             "mongodb://localhost:27017/cgminer_monitor"),
        http_host: env.fetch("CGMINER_MONITOR_HTTP_HOST", "127.0.0.1"),
        http_port: Integer(env.fetch("CGMINER_MONITOR_HTTP_PORT", "9292")),
        http_min_threads: Integer(env.fetch("CGMINER_MONITOR_HTTP_MIN_THREADS", "1")),
        http_max_threads: Integer(env.fetch("CGMINER_MONITOR_HTTP_MAX_THREADS", "5")),
        miners_file: env.fetch("CGMINER_MONITOR_MINERS_FILE", "config/miners.yml"),
        log_format: env.fetch("CGMINER_MONITOR_LOG_FORMAT", "json"),
        log_level: env.fetch("CGMINER_MONITOR_LOG_LEVEL", "info"),
        cors_origins: env.fetch("CGMINER_MONITOR_CORS_ORIGINS", "*"),
        shutdown_timeout: Integer(env.fetch("CGMINER_MONITOR_SHUTDOWN_TIMEOUT", "10")),
        healthz_stale_multiplier: Integer(env.fetch("CGMINER_MONITOR_HEALTHZ_STALE_MULTIPLIER", "2")),
        healthz_startup_grace_seconds: Integer(env.fetch("CGMINER_MONITOR_HEALTHZ_STARTUP_GRACE", "60"))
      ).validate!
    end

    def current
      @current ||= from_env
    end

    def reset!
      @current = nil
    end
  end
end
