# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'

RSpec.describe CgminerMonitor::HttpApp do
  include Rack::Test::Methods

  def app
    described_class
  end

  let(:now) { Time.utc(2026, 4, 15, 12, 0, 0) }
  let(:miner_a) { '10.0.0.5:4028' }
  let(:miners_file) { File.expand_path('../../tmp/test_miners.yml', __dir__) }

  before do
    # Set up a minimal config for the app
    CgminerMonitor::Config.reset!
    FileUtils.mkdir_p(File.dirname(miners_file))
    File.write(miners_file, "- host: 10.0.0.5\n  port: 4028\n")

    config = CgminerMonitor::Config.from_env(
      'CGMINER_MONITOR_MINERS_FILE' => miners_file,
      'CGMINER_MONITOR_CORS_ORIGINS' => '*'
    )
    CgminerMonitor::Config.instance_variable_set(:@current, config)

    described_class.started_at = Time.now.utc - 100
    described_class.poller = nil
  end

  after do
    CgminerMonitor::Config.reset!
    FileUtils.rm_f(miners_file)
    described_class.started_at = nil
    described_class.poller = nil
  end

  describe 'GET /v2/healthz' do
    context 'when mongo is reachable and a recent poll exists' do
      before do
        upsert_snapshot(miner: miner_a, command: 'summary', fetched_at: Time.now.utc)
      end

      it 'returns 200 with status healthy' do
        get '/v2/healthz'

        expect(last_response.status).to eq 200
        body = JSON.parse(last_response.body)
        expect(body['status']).to eq 'healthy'
        expect(body['mongo']).to be true
        expect(body['miners_configured']).to eq 1
      end
    end
  end

  describe 'GET /v2/miners' do
    before do
      upsert_snapshot(miner: miner_a, command: 'summary',
                      response: { 'SUMMARY' => [{}] }, fetched_at: now)
    end

    it 'returns the list of configured miners with availability' do
      get '/v2/miners'

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['miners']).to be_an(Array)
      expect(body['miners'].size).to eq 1

      miner_info = body['miners'].first
      expect(miner_info['id']).to eq miner_a
      expect(miner_info['host']).to eq '10.0.0.5'
      expect(miner_info['port']).to eq 4028
    end
  end

  describe 'GET /v2/miners/:miner/summary' do
    before do
      upsert_snapshot(miner: miner_a, command: 'summary',
                      response: { 'SUMMARY' => [{ 'GHS 5s' => 1234.56 }] },
                      fetched_at: now)
    end

    it 'returns the snapshot envelope for the miner' do
      get "/v2/miners/#{CGI.escape(miner_a)}/summary"

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['miner']).to eq miner_a
      expect(body['command']).to eq 'summary'
      expect(body['ok']).to be true
      expect(body['response']['SUMMARY']).to be_an(Array)
    end

    it 'returns 404 for an unknown miner' do
      get "/v2/miners/#{CGI.escape('1.2.3.4:9999')}/summary"

      expect(last_response.status).to eq 404
      body = JSON.parse(last_response.body)
      expect(body['code']).to eq 'not_found'
    end
  end

  describe 'GET /v2/miners/:miner/devices' do
    before do
      upsert_snapshot(miner: miner_a, command: 'devs',
                      response: { 'DEVS' => [{ 'ASC' => 0, 'Temperature' => 60.5 }] },
                      fetched_at: now)
    end

    it 'returns the devs snapshot' do
      get "/v2/miners/#{CGI.escape(miner_a)}/devices"

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['command']).to eq 'devs'
      expect(body['response']['DEVS']).to be_an(Array)
    end
  end

  describe 'GET /v2/miners/:miner/pools' do
    before do
      upsert_snapshot(miner: miner_a, command: 'pools',
                      response: { 'POOLS' => [{ 'URL' => 'stratum+tcp://pool:3333' }] },
                      fetched_at: now)
    end

    it 'returns the pools snapshot' do
      get "/v2/miners/#{CGI.escape(miner_a)}/pools"

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['command']).to eq 'pools'
    end
  end

  describe 'GET /v2/miners/:miner/stats' do
    before do
      upsert_snapshot(miner: miner_a, command: 'stats',
                      response: { 'STATS' => [{ 'ID' => 'AntS9' }] },
                      fetched_at: now)
    end

    it 'returns the stats snapshot' do
      get "/v2/miners/#{CGI.escape(miner_a)}/stats"

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['command']).to eq 'stats'
    end
  end

  describe 'GET /v2/graph_data/hashrate' do
    before do
      insert_samples(
        build_sample(miner: miner_a, command: 'summary', metric: 'ghs_5s', value: 1234.56, ts: now),
        build_sample(miner: miner_a, command: 'summary', metric: 'ghs_av', value: 1230.10, ts: now),
        build_sample(miner: miner_a, command: 'summary', metric: 'device_hardware_pct', value: 0.001, ts: now),
        build_sample(miner: miner_a, command: 'summary', metric: 'device_rejected_pct', value: 0.0, ts: now),
        build_sample(miner: miner_a, command: 'summary', metric: 'pool_rejected_pct', value: 0.0, ts: now),
        build_sample(miner: miner_a, command: 'summary', metric: 'pool_stale_pct', value: 0.0, ts: now)
      )
    end

    it 'returns hashrate data in the expected envelope' do
      get '/v2/graph_data/hashrate', miner: miner_a,
                                     since: (now - 60).iso8601,
                                     'until' => (now + 60).iso8601

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['miner']).to eq miner_a
      expect(body['metric']).to eq 'hashrate'
      expect(body['fields']).to eq %w[ts ghs_5s ghs_av device_hardware_pct
                                      device_rejected_pct pool_rejected_pct pool_stale_pct]
      expect(body['data']).to be_an(Array)
      expect(body['data'].first[1]).to eq 1234.56
    end

    it 'parses relative since parameter' do
      get '/v2/graph_data/hashrate', miner: miner_a, since: '2h'

      expect(last_response.status).to eq 200
    end

    it 'returns 400 for invalid since parameter' do
      get '/v2/graph_data/hashrate', since: 'banana'

      expect(last_response.status).to eq 400
      body = JSON.parse(last_response.body)
      expect(body['code']).to eq 'invalid_request'
    end
  end

  describe 'GET /v2/graph_data/temperature' do
    before do
      insert_samples(
        build_sample(miner: miner_a, command: 'devs', sub: 0, metric: 'temperature', value: 60.0, ts: now),
        build_sample(miner: miner_a, command: 'devs', sub: 1, metric: 'temperature', value: 70.0, ts: now)
      )
    end

    it 'returns temperature data with min/avg/max' do
      get '/v2/graph_data/temperature', miner: miner_a,
                                        since: (now - 60).iso8601,
                                        'until' => (now + 60).iso8601

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['metric']).to eq 'temperature'
      expect(body['fields']).to eq %w[ts min avg max]
      expect(body['data'].first).to eq [now.to_i, 60.0, 65.0, 70.0]
    end
  end

  describe 'GET /v2/graph_data/availability' do
    before do
      insert_samples(
        build_sample(miner: miner_a, command: 'poll', metric: 'ok', value: 1, ts: now)
      )
    end

    it 'returns availability data for a single miner' do
      get '/v2/graph_data/availability', miner: miner_a,
                                         since: (now - 60).iso8601,
                                         'until' => (now + 60).iso8601

      expect(last_response.status).to eq 200
      body = JSON.parse(last_response.body)
      expect(body['metric']).to eq 'availability'
      expect(body['fields']).to eq %w[ts available]
      expect(body['data']).to eq [[now.to_i, 1]]
    end
  end

  describe 'GET /v2/metrics' do
    before do
      upsert_snapshot(miner: miner_a, command: 'summary',
                      response: { 'SUMMARY' => [{ 'GHS 5s' => 1234.56, 'GHS av' => 1230.10 }] },
                      fetched_at: now, ok: true)
      upsert_snapshot(miner: miner_a, command: 'devs',
                      response: { 'DEVS' => [{ 'Temperature' => 60.5 }] },
                      fetched_at: now, ok: true)
    end

    it 'returns text/plain Prometheus metrics' do
      get '/v2/metrics'

      expect(last_response.status).to eq 200
      expect(last_response.content_type).to include('text/plain')
      body = last_response.body

      expect(body).to include('cgminer_hashrate_ghs')
      expect(body).to include('cgminer_available')
      expect(body).to include('cgminer_monitor_polls_total')
    end
  end

  describe 'GET /openapi.yml' do
    it 'serves the OpenAPI spec' do
      get '/openapi.yml'

      expect(last_response.status).to eq 200
      expect(last_response.content_type).to include('text/yaml')
    end
  end

  describe 'CORS headers' do
    it 'includes Access-Control-Allow-Origin' do
      get '/v2/miners', {}, { 'HTTP_ORIGIN' => 'http://localhost:3000' }

      expect(last_response.headers['access-control-allow-origin']).to eq '*'
    end
  end

  describe 'error handling' do
    it 'returns JSON error for unhandled routes' do
      get '/v2/nonexistent'

      expect(last_response.status).to eq 404
    end
  end
end
