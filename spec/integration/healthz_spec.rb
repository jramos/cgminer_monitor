# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'

RSpec.describe 'Healthz integration', :integration do
  include Rack::Test::Methods

  def app
    CgminerMonitor::HttpApp
  end

  let(:miners_file) { File.expand_path('../../tmp/healthz_miners.yml', __dir__) }

  before do
    FileUtils.mkdir_p(File.dirname(miners_file))
    File.write(miners_file, "- host: 10.0.0.5\n  port: 4028\n")

    CgminerMonitor::Config.reset!
    config = CgminerMonitor::Config.from_env(
      'CGMINER_MONITOR_INTERVAL' => '60',
      'CGMINER_MONITOR_MINERS_FILE' => miners_file,
      'CGMINER_MONITOR_CORS_ORIGINS' => '*',
      'CGMINER_MONITOR_HEALTHZ_STALE_MULTIPLIER' => '2',
      'CGMINER_MONITOR_HEALTHZ_STARTUP_GRACE' => '120'
    )
    CgminerMonitor::Config.instance_variable_set(:@current, config)
    CgminerMonitor::HttpApp.configure_for_test!(
      miners: CgminerMonitor::HttpApp.parse_miners_file(miners_file)
    )
  end

  after do
    CgminerMonitor::Config.reset!
    CgminerMonitor::HttpApp.configure_for_test!(miners: nil, poller: nil, started_at: nil)
    FileUtils.rm_f(miners_file)
  end

  context 'starting state' do
    it 'returns 200 with status starting when within grace window and no polls yet' do
      # App just started, no polls have run yet
      CgminerMonitor::HttpApp.set :started_at, Time.now.utc

      get '/v2/healthz'

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['status']).to eq 'starting'
      expect(body['mongo']).to be true
      expect(body['last_poll_at']).to be_nil
    end
  end

  context 'healthy state' do
    it 'returns 200 with status healthy after a recent successful poll' do
      CgminerMonitor::HttpApp.set :started_at, Time.now.utc - 300

      # Insert a recent snapshot
      upsert_snapshot(miner: '10.0.0.5:4028', command: 'summary', fetched_at: Time.now.utc - 10)

      get '/v2/healthz'

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['status']).to eq 'healthy'
      expect(body['mongo']).to be true
      expect(body['miners_configured']).to eq 1
      expect(body['miners_available']).to eq 1
    end
  end

  context 'degraded state — stale poll' do
    it 'returns 503 with status degraded when last poll exceeds 2x interval' do
      CgminerMonitor::HttpApp.set :started_at, Time.now.utc - 600

      # Insert a stale snapshot (older than 2 * 60s = 120s)
      upsert_snapshot(miner: '10.0.0.5:4028', command: 'summary',
                      fetched_at: Time.now.utc - 300)

      get '/v2/healthz'

      expect(last_response.status).to eq 503
      body = JSON.parse(last_response.body)
      expect(body['status']).to eq 'degraded'
    end
  end

  context 'degraded state — no polls and past grace window' do
    it 'returns 503 with status degraded when grace window has passed with no polls' do
      # App started 300s ago, grace window is 120s, and no polls exist
      CgminerMonitor::HttpApp.set :started_at, Time.now.utc - 300

      get '/v2/healthz'

      expect(last_response.status).to eq 503
      body = JSON.parse(last_response.body)
      expect(body['status']).to eq 'degraded'
    end
  end

  context 'degraded state — failed miner' do
    it 'reports miners_available correctly when a miner is down' do
      CgminerMonitor::HttpApp.set :started_at, Time.now.utc - 300

      upsert_snapshot(miner: '10.0.0.5:4028', command: 'summary',
                      ok: false, error: 'Connection refused',
                      fetched_at: Time.now.utc - 10)

      get '/v2/healthz'

      body = JSON.parse(last_response.body)
      expect(body['miners_configured']).to eq 1
      expect(body['miners_available']).to eq 0
    end
  end
end
