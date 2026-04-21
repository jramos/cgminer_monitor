# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'

RSpec.describe 'Full pipeline integration', :integration do
  include Rack::Test::Methods

  def app
    CgminerMonitor::HttpApp
  end

  let(:miners_file) { File.expand_path('../../tmp/integration_miners.yml', __dir__) }
  let(:ctx) { {} }

  around do |example|
    FakeCgminer.with do |port|
      ctx[:fake_port] = port

      FileUtils.mkdir_p(File.dirname(miners_file))
      File.write(miners_file, "- host: 127.0.0.1\n  port: #{port}\n")

      config = CgminerMonitor::Config.from_env(
        'CGMINER_MONITOR_INTERVAL' => '60',
        'CGMINER_MONITOR_MINERS_FILE' => miners_file,
        'CGMINER_MONITOR_CORS_ORIGINS' => '*'
      )
      CgminerMonitor::Config.instance_variable_set(:@current, config)

      ctx[:poller] = CgminerMonitor::Poller.new(config)
      CgminerMonitor::HttpApp.configure_for_test!(
        miners: CgminerMonitor::HttpApp.parse_miners_file(miners_file),
        poller: ctx[:poller],
        started_at: Time.now.utc
      )

      example.run

      CgminerMonitor::Config.reset!
      CgminerMonitor::HttpApp.configure_for_test!(miners: nil, poller: nil, started_at: nil)
      FileUtils.rm_f(miners_file)
    end
  end

  it 'polls a FakeCgminer, writes to Mongo, and serves via HTTP' do
    miner_id = "127.0.0.1:#{ctx[:fake_port]}"

    # --- Poll ---
    ctx[:poller].poll_once

    # --- Verify Mongo: snapshots ---
    %w[summary devs pools stats].each do |cmd|
      snapshot = CgminerMonitor::Snapshot.where(miner: miner_id, command: cmd).first
      expect(snapshot).not_to be_nil, "Missing snapshot for #{cmd}"
      expect(snapshot.ok).to be true
      expect(snapshot.response).to be_a(Hash)
      expect(snapshot.error).to be_nil
    end

    # --- Verify Mongo: synthetic poll samples ---
    poll_ok = CgminerMonitor::Sample.where(
      'meta.miner' => miner_id,
      'meta.command' => 'poll',
      'meta.metric' => 'ok'
    ).first
    expect(poll_ok).not_to be_nil
    expect(poll_ok.v).to eq 1.0

    duration = CgminerMonitor::Sample.where(
      'meta.miner' => miner_id,
      'meta.command' => 'poll',
      'meta.metric' => 'duration_ms'
    ).first
    expect(duration).not_to be_nil
    expect(duration.v).to be >= 0

    # --- HTTP: GET /v2/miners ---
    get '/v2/miners'
    expect(last_response.status).to eq 200
    body = JSON.parse(last_response.body)
    miners = body['miners']
    expect(miners.size).to eq 1
    expect(miners.first['id']).to eq miner_id
    expect(miners.first['available']).to be true

    # --- HTTP: GET /v2/miners/:miner/summary ---
    get "/v2/miners/#{CGI.escape(miner_id)}/summary"
    expect(last_response.status).to eq 200
    body = JSON.parse(last_response.body)
    expect(body['miner']).to eq miner_id
    expect(body['ok']).to be true
    expect(body['response']).to be_a(Hash)

    # --- HTTP: GET /v2/miners/:miner/devices ---
    get "/v2/miners/#{CGI.escape(miner_id)}/devices"
    expect(last_response.status).to eq 200
    body = JSON.parse(last_response.body)
    expect(body['ok']).to be true
    expect(body['response']).to be_a(Hash)

    # --- HTTP: GET /v2/miners/:miner/pools ---
    get "/v2/miners/#{CGI.escape(miner_id)}/pools"
    expect(last_response.status).to eq 200
    body = JSON.parse(last_response.body)
    expect(body['ok']).to be true
    expect(body['response']).to be_a(Hash)

    # --- HTTP: GET /v2/miners/:miner/stats ---
    get "/v2/miners/#{CGI.escape(miner_id)}/stats"
    expect(last_response.status).to eq 200
    body = JSON.parse(last_response.body)
    expect(body['ok']).to be true
    expect(body['response']).to be_a(Hash)

    # --- HTTP: GET /v2/graph_data/availability ---
    get '/v2/graph_data/availability', miner: miner_id, since: '1h'
    expect(last_response.status).to eq 200
    body = JSON.parse(last_response.body)
    expect(body['metric']).to eq 'availability'
    expect(body['data']).to be_an(Array)
    expect(body['data'].size).to be >= 1
    expect(body['data'].first[1]).to eq 1 # available

    # --- HTTP: GET /v2/metrics ---
    get '/v2/metrics'
    expect(last_response.status).to eq 200
    expect(last_response.body).to include('cgminer_available')
    expect(last_response.body).to include("cgminer_available{miner=\"#{miner_id}\"} 1")
    expect(last_response.body).to include('cgminer_monitor_polls_total{result="ok"} 1')
  end

  it 'handles a failed miner poll gracefully' do
    # Use a port where nothing is listening
    server = TCPServer.new('127.0.0.1', 0)
    closed_port = server.addr[1]
    server.close

    FileUtils.mkdir_p(File.dirname(miners_file))
    File.write(miners_file, "- host: 127.0.0.1\n  port: #{closed_port}\n")

    config = CgminerMonitor::Config.from_env(
      'CGMINER_MONITOR_INTERVAL' => '60',
      'CGMINER_MONITOR_MINERS_FILE' => miners_file,
      'CGMINER_MONITOR_CORS_ORIGINS' => '*'
    )
    CgminerMonitor::Config.instance_variable_set(:@current, config)

    poller = CgminerMonitor::Poller.new(config)

    # Should not raise
    expect { poller.poll_once }.not_to raise_error

    miner_id = "127.0.0.1:#{closed_port}"

    # Snapshot should record failure
    snapshot = CgminerMonitor::Snapshot.where(miner: miner_id, command: 'summary').first
    expect(snapshot).not_to be_nil
    expect(snapshot.ok).to be false
    expect(snapshot.error).not_to be_nil

    # Synthetic poll/ok=0 sample
    poll_ok = CgminerMonitor::Sample.where(
      'meta.miner' => miner_id,
      'meta.command' => 'poll',
      'meta.metric' => 'ok'
    ).first
    expect(poll_ok.v).to eq 0.0
  end
end
