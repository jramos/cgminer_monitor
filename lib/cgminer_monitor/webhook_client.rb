# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module CgminerMonitor
  # POSTs a formatted JSON body to the configured webhook URL, one attempt,
  # with a tight connect+read timeout. Failures never re-raise — they
  # log alert.webhook_failed and return. The poll loop and evaluator
  # continue regardless: state persisted = semantic event happened,
  # even if the sink missed the notification.
  class WebhookClient
    # Slack's attachments[] shape is marked "legacy" by Slack but remains
    # stable and is the simplest body that renders with a color sidebar.
    # Block Kit (blocks[]) does not support the colored sidebar, so it's
    # not a drop-in upgrade here.
    SLACK_COLOR = { 'alert.fired' => 'warning', 'alert.resolved' => 'good' }.freeze

    # Discord embed `color` is a decimal RGB integer, not a hex string.
    DISCORD_COLOR = { 'alert.fired' => 15_844_367, 'alert.resolved' => 2_664_261 }.freeze

    def initialize(config)
      @url     = config.alerts_webhook_url
      @format  = config.alerts_webhook_format
      @timeout = config.alerts_webhook_timeout_seconds
    end

    def fire(event:, miner:, rule:, threshold:, observed:, unit:, fired_at:)
      payload = { event: event, miner: miner, rule: rule, threshold: threshold,
                  observed: observed, unit: unit, fired_at: fired_at.utc.iso8601(3) }
      post(JSON.generate(body_for(payload)), miner: miner, rule: rule)
    rescue StandardError => e
      # Belt-and-braces: any path that slipped past the inner rescue
      # below still can't propagate out of here.
      Logger.warn(event: 'alert.webhook_failed', miner: miner, rule: rule,
                  error: e.class.to_s, message: e.message)
    end

    private

    def post(json, miner:, rule:)
      uri = URI.parse(@url)
      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 open_timeout: @timeout,
                                 read_timeout: @timeout) do |http|
        req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
        req.body = json
        http.request(req)
      end

      return if response.is_a?(Net::HTTPSuccess)

      Logger.warn(event: 'alert.webhook_failed', miner: miner, rule: rule,
                  status: response.code.to_i,
                  error: 'HTTPError', message: "webhook returned #{response.code}")
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
      Logger.warn(event: 'alert.webhook_failed', miner: miner, rule: rule,
                  error: e.class.to_s, message: e.message)
    end

    def body_for(payload)
      case @format
      when 'slack'   then slack_body(payload)
      when 'discord' then discord_body(payload)
      else generic_body(payload)
      end
    end

    def generic_body(payload)
      payload.merge(severity: 'warning',
                    monitor: { version: CgminerMonitor::VERSION, pid: Process.pid })
    end

    def slack_body(payload)
      title = "#{slack_title(payload[:rule], payload[:event])} — #{payload[:miner]}"
      {
        attachments: [{
          color: SLACK_COLOR[payload[:event]] || 'warning',
          title: title,
          fields: [
            { title: 'Observed',  value: "#{payload[:observed]} #{payload[:unit]}",  short: true },
            { title: 'Threshold', value: "#{payload[:threshold]} #{payload[:unit]}", short: true }
          ],
          ts: Time.parse(payload[:fired_at]).to_i
        }]
      }
    end

    def discord_body(payload)
      {
        embeds: [{
          title: slack_title(payload[:rule], payload[:event]),
          description: "Miner `#{payload[:miner]}` observed #{payload[:observed]} #{payload[:unit]} " \
                       "(threshold #{payload[:threshold]} #{payload[:unit]}).",
          color: DISCORD_COLOR[payload[:event]] || 15_844_367,
          timestamp: payload[:fired_at]
        }]
      }
    end

    RULE_TITLES = {
      'hashrate_below' => 'Hashrate below threshold',
      'temperature_above' => 'Temperature above threshold',
      'offline' => 'Miner offline'
    }.freeze
    private_constant :RULE_TITLES

    def slack_title(rule, event)
      base = RULE_TITLES[rule]
      event == 'alert.resolved' ? "#{base} — resolved" : base
    end
  end
end
