# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

RSpec.describe CgminerMonitor::WebhookClient do
  subject(:client) { described_class.new(config) }

  let(:miners_file_path) do
    path = File.expand_path('../../tmp/test_webhook_miners.yml', __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "- host: 10.0.0.5\n  port: 4028\n")
    path
  end

  let(:webhook_url) { 'http://example.test/hook' }
  let(:fired_at) { Time.utc(2026, 4, 24, 17, 3, 2, 697_000) }
  let(:payload) do
    { event: 'alert.fired',
      miner: '10.0.0.5:4028',
      rule: 'temperature_above',
      threshold: 85.0,
      observed: 92.5,
      unit: 'C',
      fired_at: fired_at }
  end

  def make_config(format)
    CgminerMonitor::Config.from_env(
      'CGMINER_MONITOR_MINERS_FILE' => miners_file_path,
      'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
      'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => webhook_url,
      'CGMINER_MONITOR_ALERTS_WEBHOOK_FORMAT' => format,
      'CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '85',
      'CGMINER_MONITOR_ALERTS_WEBHOOK_TIMEOUT_SECONDS' => '2'
    )
  end

  def last_posted_body
    body = nil
    WebMock::RequestRegistry.instance.requested_signatures.hash.each_key do |sig|
      body = sig.body if sig.method == :post
    end
    JSON.parse(body)
  end

  before do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
    CgminerMonitor::Logger.output = StringIO.new
    CgminerMonitor::Logger.level = 'error'
  end

  after do
    CgminerMonitor::Logger.output = $stdout
    CgminerMonitor::Logger.level = 'info'
    FileUtils.rm_f(miners_file_path)
    WebMock.reset!
    WebMock.disable!
  end

  describe 'generic format' do
    let(:config) { make_config('generic') }

    it 'POSTs a JSON body with event, miner, rule, severity, monitor metadata' do
      stub_request(:post, webhook_url).to_return(status: 200)
      client.fire(**payload)

      body = last_posted_body
      expect(body).to include(
        'event' => 'alert.fired',
        'miner' => '10.0.0.5:4028',
        'rule' => 'temperature_above',
        'threshold' => 85.0,
        'observed' => 92.5,
        'unit' => 'C',
        'severity' => 'warning'
      )
      expect(body['monitor']).to include('version' => CgminerMonitor::VERSION, 'pid' => Process.pid)
      expect(body['fired_at']).to eq '2026-04-24T17:03:02.697Z'
      expect(WebMock).to have_requested(:post, webhook_url)
        .with(headers: { 'Content-Type' => 'application/json' })
    end
  end

  describe 'slack format' do
    let(:config) { make_config('slack') }

    it 'POSTs a Slack attachments[] body with warning color on alert.fired' do
      stub_request(:post, webhook_url).to_return(status: 200)
      client.fire(**payload)

      att = last_posted_body.fetch('attachments').first
      expect(att['color']).to eq 'warning'
      expect(att['title']).to include('Temperature above threshold')
      expect(att['title']).to include('10.0.0.5:4028')
      expect(att['fields']).to contain_exactly(
        { 'title' => 'Observed',  'value' => '92.5 C', 'short' => true },
        { 'title' => 'Threshold', 'value' => '85.0 C', 'short' => true }
      )
      expect(att['ts']).to eq fired_at.to_i
    end

    it 'uses good color on alert.resolved' do
      stub_request(:post, webhook_url).to_return(status: 200)
      client.fire(**payload, event: 'alert.resolved')

      att = last_posted_body.fetch('attachments').first
      expect(att['color']).to eq 'good'
      expect(att['title']).to include('resolved')
    end
  end

  describe 'discord format' do
    let(:config) { make_config('discord') }

    it 'POSTs a Discord embeds[] body with decimal RGB color' do
      stub_request(:post, webhook_url).to_return(status: 204)
      client.fire(**payload)

      embed = last_posted_body.fetch('embeds').first
      expect(embed['color']).to eq 15_844_367
      expect(embed['title']).to eq 'Temperature above threshold'
      expect(embed['description']).to include('10.0.0.5:4028')
      expect(embed['description']).to include('92.5 C')
      expect(embed['description']).to include('85.0 C')
      expect(embed['timestamp']).to eq '2026-04-24T17:03:02.697Z'
    end
  end

  describe 'composite-rule payload (details + unit elision)' do
    let(:composite_payload) do
      { event: 'alert.fired',
        miner: '10.0.0.5:4028',
        rule: 'thermal_stress',
        threshold: 'ghs_5s<500.0 & temp_max>80.0',
        observed: 'ghs_5s=450.5 temp_max=82.3',
        unit: nil,
        fired_at: fired_at,
        details: { 'expression' => 'ghs_5s<500.0 & temp_max>80.0',
                   'clauses' => { 'ghs_5s' => { 'observed' => 450.5, 'threshold' => 500.0, 'op' => '<' } } } }
    end

    context 'with generic format' do
      let(:config) { make_config('generic') }

      it 'includes the structured details hash in the body' do
        stub_request(:post, webhook_url).to_return(status: 200)
        client.fire(**composite_payload)

        body = last_posted_body
        expect(body['rule']).to eq 'thermal_stress'
        expect(body['unit']).to be_nil
        expect(body['details']).to include('expression' => 'ghs_5s<500.0 & temp_max>80.0')
      end

      it 'omits the details key from built-in-rule payloads (no nil noise)' do
        stub_request(:post, webhook_url).to_return(status: 200)
        client.fire(**payload) # built-in rule, no details: passed
        expect(last_posted_body).not_to have_key('details')
      end
    end

    context 'with slack format' do
      let(:config) { make_config('slack') }

      it 'renders observed/threshold without trailing space when unit is nil' do
        stub_request(:post, webhook_url).to_return(status: 200)
        client.fire(**composite_payload)

        att = last_posted_body.fetch('attachments').first
        expect(att['title']).to include('Composite alert: thermal_stress')
        observed = att['fields'].find { |f| f['title'] == 'Observed' }
        threshold = att['fields'].find { |f| f['title'] == 'Threshold' }
        expect(observed['value']).to eq 'ghs_5s=450.5 temp_max=82.3' # no trailing " "
        expect(threshold['value']).to eq 'ghs_5s<500.0 & temp_max>80.0'
      end
    end

    context 'with discord format' do
      let(:config) { make_config('discord') }

      it 'renders description without double spaces when unit is nil' do
        stub_request(:post, webhook_url).to_return(status: 204)
        client.fire(**composite_payload)

        embed = last_posted_body.fetch('embeds').first
        expect(embed['title']).to eq 'Composite alert: thermal_stress'
        expect(embed['description']).to include('observed ghs_5s=450.5 temp_max=82.3 ')
        expect(embed['description']).to include('(threshold ghs_5s<500.0 & temp_max>80.0)')
        expect(embed['description']).not_to include('  ') # no double spaces
      end
    end
  end

  describe 'failure handling' do
    let(:config) { make_config('generic') }
    let(:log_io) { StringIO.new }

    def last_log_event
      log_io.string.lines.map { |l| JSON.parse(l) }.last
    end

    before do
      CgminerMonitor::Logger.output = log_io
      CgminerMonitor::Logger.level = 'warn'
    end

    it 'logs alert.webhook_failed with status on non-2xx responses' do
      stub_request(:post, webhook_url).to_return(status: 500, body: 'boom')

      expect { client.fire(**payload) }.not_to raise_error

      entry = last_log_event
      expect(entry['event']).to eq 'alert.webhook_failed'
      expect(entry['status']).to eq 500
      expect(entry['miner']).to eq '10.0.0.5:4028'
      expect(entry['rule']).to eq 'temperature_above'
    end

    it 'logs alert.webhook_failed on open timeout' do
      stub_request(:post, webhook_url).to_raise(Net::OpenTimeout.new('timed out'))

      expect { client.fire(**payload) }.not_to raise_error

      entry = last_log_event
      expect(entry['event']).to eq 'alert.webhook_failed'
      expect(entry['error']).to eq 'Net::OpenTimeout'
    end

    it 'logs alert.webhook_failed on connection refused' do
      stub_request(:post, webhook_url).to_raise(Errno::ECONNREFUSED)

      expect { client.fire(**payload) }.not_to raise_error

      entry = last_log_event
      expect(entry['event']).to eq 'alert.webhook_failed'
      expect(entry['error']).to eq 'Errno::ECONNREFUSED'
    end
  end
end
