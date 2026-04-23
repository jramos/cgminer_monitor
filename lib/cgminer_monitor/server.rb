# frozen_string_literal: true

require 'puma'
require 'puma/configuration'
require 'puma/launcher'

module CgminerMonitor
  class Server
    attr_reader :config, :poller

    def initialize(config)
      @config  = config
      @poller  = Poller.new(config)
      @signals = Queue.new
      @booted  = Queue.new
    end

    def run
      install_signal_handlers # MUST install BEFORE Puma's Launcher.run
      configure_mongoid!
      validate_startup!
      bootstrap_mongoid!

      # Wire app state into HttpApp's Sinatra settings so routes can
      # read via `settings.foo`. Server owns the write; HttpApp owns
      # the read. All writes happen here, before Puma accepts its
      # first request — no lazy loading, no per-request config drift.
      HttpApp.set :poller,             @poller
      HttpApp.set :started_at,         Time.now.utc
      HttpApp.set :configured_miners,  HttpApp.parse_miners_file(@config.miners_file)

      Logger.info(event: 'server.start',
                  pid: Process.pid,
                  bind: @config.http_host,
                  port: @config.http_port,
                  log_format: @config.log_format,
                  log_level: @config.log_level,
                  mongo_url: @config.public_attrs[:mongo_url])

      poller_thread = Thread.new { @poller.run_until_stopped(@signals) }
      puma_launcher = build_puma_launcher
      puma_thread   = start_puma_thread(puma_launcher)

      # Wait for Puma's launcher.events.on_booted before reinstalling
      # our traps. Puma's setup_signals runs synchronously during
      # launcher.run and overwrites our handlers — including
      # installing its own SIGHUP trap (which calls stop() when
      # stdout_redirect is unset), which would shut us down instead of
      # triggering a reload. on_booted is deterministic; the previous
      # sleep(0.05) was racy.
      @booted.pop
      install_signal_handlers

      write_pid_file

      dispatch_signals_until_stop

      Logger.info(event: 'server.stopping')

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
    ensure
      unlink_pid_file
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

    def start_puma_thread(launcher)
      Thread.new do
        launcher.run
      rescue Exception => e # rubocop:disable Lint/RescueException
        Logger.error(event: 'puma.crash', error: e.class.to_s,
                     message: e.message, backtrace: e.backtrace&.first(10))
        @booted << true # unblock main if we died before booting
        @signals << :stop
      end
    end

    def install_signal_handlers
      Signal.trap('INT')  { @signals << :stop }
      Signal.trap('TERM') { @signals << :stop }
      Signal.trap('HUP')  { @signals << :reload }
    end

    def dispatch_signals_until_stop
      loop do
        case @signals.pop
        when :reload then perform_reload
        when :stop   then break
        end
      end
    end

    # Two-step reload: Poller holds the live MinerPool the poll loop
    # iterates; HttpApp holds the route-read miner list. Both must
    # agree for a clean reload. Each side logs reload.failed on its
    # own parse failure; this dispatcher adds:
    #   - reload.ok when both succeeded
    #   - reload.partial when exactly one succeeded (inconsistent state
    #     until the next reload; operator needs to know which half won)
    #   - nothing when both failed (both reload.failed log lines are
    #     enough signal; a dispatcher-level event would just duplicate)
    def perform_reload
      Logger.info(event: 'reload.signal_received')
      pool_count = @poller.reload!
      app_count  = HttpApp.reload_miners!(@config.miners_file)

      if pool_count && app_count
        Logger.info(event: 'reload.ok', miners: pool_count)
      elsif pool_count || app_count
        Logger.error(event: 'reload.partial',
                     poller_ok: !pool_count.nil?,
                     http_app_ok: !app_count.nil?)
      end
    end

    def write_pid_file
      return unless @config.pid_file

      File.write(@config.pid_file, "#{Process.pid}\n")
      Logger.info(event: 'server.pid_file_written', path: @config.pid_file)
    end

    def unlink_pid_file
      return unless @config.pid_file

      File.unlink(@config.pid_file)
    rescue Errno::ENOENT
      # already gone — shutdown raced with external cleanup; fine
    end

    def build_puma_launcher
      app = HttpApp
      config = @config
      booted = @booted

      puma_config = Puma::Configuration.new do |user_config|
        user_config.bind "tcp://#{config.http_host}:#{config.http_port}"
        user_config.threads config.http_min_threads, config.http_max_threads
        user_config.workers 0
        user_config.app app
        user_config.log_requests false
        user_config.quiet
        # Prevent Puma from installing its own SIGTERM handler, which would
        # overwrite our @signals-queue-based handler. We handle shutdown ourselves
        # via launcher.stop called from the main thread.
        user_config.raise_exception_on_sigterm false
      end

      launcher = Puma::Launcher.new(puma_config)
      launcher.events.on_booted { booted << true }
      launcher
    end
  end
end
