# frozen_string_literal: true

require 'puma'
require 'puma/configuration'
require 'puma/launcher'

module CgminerMonitor
  class Server
    class << self
      attr_accessor :started_at, :poller
    end

    attr_reader :config, :poller

    def initialize(config)
      @config = config
      @poller = Poller.new(config)
      @stop   = Queue.new
    end

    def run
      install_signal_handlers # MUST install BEFORE Puma's Launcher.run
      configure_mongoid!
      validate_startup!
      bootstrap_mongoid!

      self.class.started_at = Time.now.utc
      self.class.poller = @poller

      # Wire the poller into HttpApp so metrics/healthz can read it
      HttpApp.poller = @poller
      HttpApp.started_at = self.class.started_at

      Logger.info(event: 'server.start', pid: Process.pid,
                  config: @config.public_attrs)

      poller_thread = Thread.new { @poller.run_until_stopped(@stop) }
      puma_launcher = build_puma_launcher
      puma_thread = Thread.new do
        puma_launcher.run
      rescue Exception => e # rubocop:disable Lint/RescueException
        Logger.error(event: 'puma.crash', error: e.class.to_s,
                     message: e.message, backtrace: e.backtrace&.first(10))
        @stop << 'puma_crash'
      end
      reinstall_signal_handlers # Re-install after Puma's setup_signals runs

      signal = @stop.pop # blocks until SIGTERM/SIGINT
      Logger.info(event: 'server.stopping', signal: signal)

      @poller.stop
      poller_thread.join(@config.shutdown_timeout)
      puma_launcher.stop
      puma_thread.join(@config.shutdown_timeout)

      Logger.info(event: 'server.stopped')
      0
    rescue StandardError => e
      Logger.error(event: 'server.crash', error: e.class.to_s,
                   message: e.message, backtrace: e.backtrace)
      1
    end

    # --- Startup ---

    def configure_mongoid!
      Mongoid.configure do |c|
        c.clients.default = { uri: @config.mongo_url }
      end
    end

    def validate_startup!
      # Verify miners.yml parses
      miners_config = YAML.safe_load_file(@config.miners_file)
      raise ConfigError, "miners_file is empty" if miners_config.nil? || miners_config.empty?

      # Verify Mongo is reachable
      Mongoid.default_client.database_names
    rescue Mongo::Error => e
      Logger.error(event: 'startup.mongo_unreachable', error: e.class.to_s, message: e.message)
      raise
    end

    def bootstrap_mongoid!
      Sample.store_in(
        collection: 'samples',
        collection_options: {
          time_series: {
            timeField: 'ts',
            metaField: 'meta',
            granularity: 'minutes'
          },
          expire_after: @config.retention_seconds
        }
      )
      Sample.create_collection
      Snapshot.create_indexes
    end

    private

    def install_signal_handlers
      %w[TERM INT].each do |sig|
        Signal.trap(sig) { @stop << sig }
      end
    end

    def build_puma_launcher
      app = HttpApp
      config = @config

      puma_config = Puma::Configuration.new do |user_config|
        user_config.bind "tcp://#{config.http_host}:#{config.http_port}"
        user_config.threads config.http_min_threads, config.http_max_threads
        user_config.workers 0
        user_config.app app
        user_config.log_requests false
        user_config.quiet
        # Prevent Puma from installing its own SIGTERM handler, which would
        # overwrite our @stop-queue-based handler. We handle shutdown ourselves
        # via launcher.stop called from the main thread.
        user_config.raise_exception_on_sigterm false
      end

      Puma::Launcher.new(puma_config)
    end

    def reinstall_signal_handlers
      # Puma::Launcher#run calls setup_signals synchronously, which overwrites
      # process-global signal handlers. We re-install ours after a brief yield
      # to let Puma's thread start. Even with raise_exception_on_sigterm false,
      # Puma may still install handlers for other signals.
      sleep 0.05
      install_signal_handlers
    end
  end
end
