# frozen_string_literal: true

require 'sinatra/base'
require 'rack/cors'
require 'json'
require 'cgi/escape'
require 'yaml'
require 'time'

module CgminerMonitor
  class HttpApp < Sinatra::Base
    set :show_exceptions, false
    set :dump_errors, false
    set :host_authorization, { permitted_hosts: [] }

    # App state set by Server#run before Puma accepts its first request.
    # Defaults intentionally `nil` so an unconfigured App fails loud on the
    # first read rather than silently returning empty data. See the
    # `configured_miners` helper below.
    set :poller,            nil
    set :started_at,        nil
    set :configured_miners, nil

    # Wraps the raw YAML parse behind a stable shape so Server#run (and
    # the test helper below) can eager-populate `settings.configured_miners`.
    # Returns a frozen Array of `[miner_id, host, port]` tuples. Raises
    # ConfigError on shape errors (non-Array top level, list entry not
    # a Hash, or Hash missing `host`) so callers don't have to rescue
    # NoMethodError/TypeError just to distinguish "malformed miners
    # file" from "bug in our code."
    def self.parse_miners_file(path)
      raw = YAML.safe_load_file(path)
      validate_miners_shape!(path, raw)
      raw.map do |m|
        host = m['host']
        port = m['port'] || 4028
        ["#{host}:#{port}", host, port]
      end.freeze
    end

    def self.validate_miners_shape!(path, raw)
      return if raw.is_a?(Array) && raw.all? { |m| m.is_a?(Hash) && m['host'] }

      raise ConfigError, "#{path} must be a YAML list of {host, port} entries"
    end
    private_class_method :validate_miners_shape!

    # Re-parses the given miners file and atomically swaps
    # `settings.configured_miners`. Returns the new miner count on
    # success, nil on parse/validation/IO failure — the old setting is
    # untouched on failure so in-flight readers never see a torn state.
    def self.reload_miners!(path)
      new_miners = parse_miners_file(path)
      set :configured_miners, new_miners
      new_miners.size
    rescue ConfigError, Errno::ENOENT, Psych::SyntaxError => e
      Logger.warn(event: 'reload.failed',
                  error: e.class.to_s, message: e.message)
      nil
    end

    # Sentinel so the default "give me a current timestamp" behavior for
    # `started_at:` stays available without making nil-as-explicit-clear
    # impossible to express.
    STARTED_AT_DEFAULT = Object.new.freeze
    private_constant :STARTED_AT_DEFAULT

    # Spec convenience. Keeps the "set every setting in one place" shape so
    # the test-order footgun doesn't reopen if someone adds a new setting
    # and forgets to null it out in between examples.
    #
    # Omitting `started_at:` defaults to `Time.now.utc`. Passing `nil`
    # explicitly writes `nil` — use this in `after` blocks to clear the
    # setting.
    def self.configure_for_test!(miners:, poller: nil, started_at: STARTED_AT_DEFAULT)
      set :configured_miners, miners
      set :poller,             poller
      set :started_at,         started_at.equal?(STARTED_AT_DEFAULT) ? Time.now.utc : started_at
    end

    configure do
      use CgminerMonitor::RequestId
      use Rack::Cors do
        allow do
          cors = Config.current.cors_origins
          if cors == '*'
            origins '*'
          else
            origins(*cors.split(',').map(&:strip))
          end
          resource '*', headers: :any, methods: %i[get options]
        end
      end
    end

    before do
      @request_id = request.env[CgminerMonitor::RequestId::ENV_KEY]
      @started_at = Time.now
      content_type :json
    end

    after do
      Logger.info(
        event: 'http.request',
        request_id: @request_id,
        method: request.request_method,
        path: request.path_info,
        status: response.status,
        duration_ms: ((Time.now - @started_at) * 1000).round
      )
    end

    # --- Health ---

    get '/v2/healthz' do
      health = build_health_check
      http_status = health[:status] == 'degraded' ? 503 : 200
      status http_status
      JSON.generate(health)
    end

    # --- Prometheus Metrics ---

    get '/v2/metrics' do
      content_type 'text/plain; version=0.0.4; charset=utf-8'
      build_prometheus_metrics
    end

    # --- Miners ---

    get '/v2/miners' do
      snapshot_info = SnapshotQuery.miners.to_h { |m| [m[:miner], m] }

      miners = configured_miners.map do |miner_id, host, port|
        info = snapshot_info[miner_id]
        {
          id: miner_id,
          host: host,
          port: port,
          available: info ? info[:ok] : false,
          last_poll: info ? info[:fetched_at]&.utc&.iso8601 : nil
        }
      end

      JSON.generate({ miners: miners })
    end

    # --- Miner detail routes ---

    get '/v2/miners/:miner/devices' do
      miner_snapshot('devs')
    end

    get '/v2/miners/:miner/pools' do
      miner_snapshot('pools')
    end

    get '/v2/miners/:miner/summary' do
      miner_snapshot('summary')
    end

    get '/v2/miners/:miner/stats' do
      miner_snapshot('stats')
    end

    # --- Graph Data ---

    get '/v2/graph_data/hashrate' do
      miner = params['miner']
      since_t, until_t = parse_time_range

      data = SampleQuery.hashrate(miner: miner, since: since_t, until_: until_t)

      cache_control :public, max_age: Config.current.interval

      JSON.generate({
                      miner: miner,
                      metric: 'hashrate',
                      since: since_t.utc.iso8601,
                      'until' => until_t.utc.iso8601,
                      fields: %w[ts ghs_5s ghs_av device_hardware_pct device_rejected_pct pool_rejected_pct
                                 pool_stale_pct],
                      data: data
                    })
    end

    get '/v2/graph_data/temperature' do
      miner = params['miner']
      since_t, until_t = parse_time_range

      data = SampleQuery.temperature(miner: miner, since: since_t, until_: until_t)

      cache_control :public, max_age: Config.current.interval

      JSON.generate({
                      miner: miner,
                      metric: 'temperature',
                      since: since_t.utc.iso8601,
                      'until' => until_t.utc.iso8601,
                      fields: %w[ts min avg max],
                      data: data
                    })
    end

    get '/v2/graph_data/availability' do
      miner = params['miner']
      since_t, until_t = parse_time_range

      data = SampleQuery.availability(miner: miner, since: since_t, until_: until_t)
      fields = miner ? %w[ts available] : %w[ts available configured]

      cache_control :public, max_age: Config.current.interval

      JSON.generate({
                      miner: miner,
                      metric: 'availability',
                      since: since_t.utc.iso8601,
                      'until' => until_t.utc.iso8601,
                      fields: fields,
                      data: data
                    })
    end

    # --- OpenAPI / Docs ---

    get '/openapi.yml' do
      content_type 'text/yaml; charset=utf-8'
      openapi_path = File.expand_path('openapi.yml', __dir__)
      send_file openapi_path
    end

    get '/docs' do
      content_type :html
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <title>cgminer_monitor API</title>
          <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
        </head>
        <body>
          <div id="swagger-ui"></div>
          <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
          <script>
            SwaggerUIBundle({ url: '/openapi.yml', dom_id: '#swagger-ui' });
          </script>
        </body>
        </html>
      HTML
    end

    # --- Error handlers ---

    not_found do
      content_type :json
      JSON.generate({ error: 'not found', code: 'not_found' })
    end

    error do
      err = env['sinatra.error']
      Logger.error(event: 'http.unhandled_error',
                   request_id: env[CgminerMonitor::RequestId::ENV_KEY],
                   error: err.class.to_s,
                   message: err.message,
                   backtrace: err.backtrace&.first(10))
      content_type :json
      status 500
      JSON.generate({ error: 'internal', code: 'internal' })
    end

    private

    def build_health_check
      config = Config.current
      mongo_ok = mongo_reachable?

      miners_info = SnapshotQuery.miners
      last_poll = miners_info.map { |m| m[:fetched_at] }.compact.max
      last_poll_age_s = last_poll ? (Time.now.utc - last_poll).to_i : nil
      miners_available = miners_info.count { |m| m[:ok] }

      app_started_at = settings.started_at
      uptime_s = app_started_at ? (Time.now.utc - app_started_at).to_i : 0
      stale_threshold = config.interval * config.healthz_stale_multiplier

      status_value = if mongo_ok && last_poll.nil? && uptime_s < config.healthz_startup_grace_seconds
                       'starting'
                     elsif mongo_ok && last_poll && last_poll_age_s && last_poll_age_s < stale_threshold
                       'healthy'
                     else
                       'degraded'
                     end

      {
        status: status_value, mongo: mongo_ok,
        last_poll_at: last_poll&.utc&.iso8601, last_poll_age_s: last_poll_age_s,
        miners_configured: configured_miners.size, miners_available: miners_available,
        uptime_s: uptime_s
      }
    end

    # Fail-loud accessor — an unconfigured App raises a clear error
    # instead of silently returning an empty miners list.
    def configured_miners
      settings.configured_miners || raise(
        'HttpApp not configured; call Server#run or configure_for_test!'
      )
    end

    def prom_escape(value)
      value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("\n", '\\n')
    end

    def configured_miner_ids
      configured_miners.map(&:first)
    end

    def miner_snapshot(command)
      miner_id = CGI.unescape(params['miner'])

      unless configured_miner_ids.include?(miner_id)
        halt 404, JSON.generate({ error: "unknown miner: #{miner_id}", code: 'not_found' })
      end

      snapshot = SnapshotQuery.for_miner(miner: miner_id, command: command)

      if snapshot
        JSON.generate({
                        miner: miner_id,
                        command: command,
                        fetched_at: snapshot.fetched_at&.utc&.iso8601,
                        ok: snapshot.ok,
                        response: snapshot.response,
                        error: snapshot.error
                      })
      else
        JSON.generate({
                        miner: miner_id,
                        command: command,
                        fetched_at: nil,
                        ok: nil,
                        response: nil,
                        error: nil
                      })
      end
    end

    def parse_time_range
      now = Time.now.utc
      since_t = parse_time_param(params['since'], now - 3600)
      until_t = parse_time_param(params['until'], now)
      [since_t, until_t]
    end

    def parse_time_param(value, default)
      return default if value.nil? || value.empty?

      # Try relative time first: Nh, Nm, Nd, Nw
      if (match = value.match(/\A(\d+)([hmwdHMWD])\z/))
        amount = match[1].to_i
        unit = match[2].downcase
        seconds = case unit
                  when 'h' then amount * 3600
                  when 'm' then amount * 60
                  when 'd' then amount * 86_400
                  when 'w' then amount * 604_800
                  end
        return Time.now.utc - seconds
      end

      # Try ISO-8601
      Time.parse(value).utc
    rescue ArgumentError
      halt 400, JSON.generate({ error: "invalid time parameter: #{value}", code: 'invalid_request' })
    end

    def mongo_reachable?
      Mongoid.default_client.database_names
      true
    rescue Mongo::Error => e
      Logger.warn(event: 'healthz.mongo_unreachable', error: e.class.to_s, message: e.message)
      false
    end

    def build_prometheus_metrics
      lines = []

      # Hashrate gauges from latest snapshots
      lines << '# HELP cgminer_hashrate_ghs Current cgminer hashrate in GH/s'
      lines << '# TYPE cgminer_hashrate_ghs gauge'

      Snapshot.where(command: 'summary', ok: true).each do |snap|
        summary = snap.response&.dig('SUMMARY')&.first
        next unless summary

        ghs_5s = summary['GHS 5s'] || summary['ghs_5s']
        ghs_av = summary['GHS av'] || summary['ghs_av']
        lines << "cgminer_hashrate_ghs{miner=\"#{prom_escape(snap.miner)}\",window=\"5s\"} #{ghs_5s}" if ghs_5s
        lines << "cgminer_hashrate_ghs{miner=\"#{prom_escape(snap.miner)}\",window=\"avg\"} #{ghs_av}" if ghs_av
      end

      # Temperature gauges from latest devs snapshots
      lines << ''
      lines << '# HELP cgminer_temperature_celsius Per-device temperature'
      lines << '# TYPE cgminer_temperature_celsius gauge'

      Snapshot.where(command: 'devs', ok: true).each do |snap|
        devices = snap.response&.dig('DEVS') || []
        devices.each_with_index do |dev, i|
          temp = dev['Temperature'] || dev['temperature']
          lines << "cgminer_temperature_celsius{miner=\"#{prom_escape(snap.miner)}\",device=\"#{i}\"} #{temp}" if temp
        end
      end

      # Availability gauge
      lines << ''
      lines << '# HELP cgminer_available Whether the miner responded to the most recent poll'
      lines << '# TYPE cgminer_available gauge'

      configured_miner_ids.each do |miner_id|
        latest = Snapshot.where(miner: miner_id).order_by(fetched_at: :desc).first
        available = latest&.ok ? 1 : 0
        lines << "cgminer_available{miner=\"#{prom_escape(miner_id)}\"} #{available}"
      end

      # Polls counter
      lines << ''
      lines << '# HELP cgminer_monitor_polls_total Total polls performed'
      lines << '# TYPE cgminer_monitor_polls_total counter'

      poller = settings.poller
      if poller
        lines << "cgminer_monitor_polls_total{result=\"ok\"} #{poller.polls_ok}"
        lines << "cgminer_monitor_polls_total{result=\"failed\"} #{poller.polls_failed}"
      else
        lines << 'cgminer_monitor_polls_total{result="ok"} 0'
        lines << 'cgminer_monitor_polls_total{result="failed"} 0'
      end

      # Last poll age
      lines << ''
      lines << '# HELP cgminer_monitor_last_poll_age_seconds Seconds since last successful poll'
      lines << '# TYPE cgminer_monitor_last_poll_age_seconds gauge'

      last_poll = SnapshotQuery.miners.map { |m| m[:fetched_at] }.compact.max
      age = last_poll ? (Time.now.utc - last_poll).to_i : -1
      lines << "cgminer_monitor_last_poll_age_seconds #{age}"

      "#{lines.join("\n")}\n"
    end
  end
end
