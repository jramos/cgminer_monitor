# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# End-to-end alerts: real Mongo, real AlertEvaluator + WebhookClient,
# WebMock-stubbed sink. Exercises the two edge-case paths the unit
# specs can only partially cover — a full fired -> resolved cycle and
# a cooldown re-fire — through the same wiring a running service uses.
RSpec.describe 'Alerts integration', :integration do
  let(:miners_file_path) do
    path = File.expand_path('../../tmp/test_alerts_integration_miners.yml', __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "- host: 10.0.0.5\n  port: 4028\n")
    path
  end

  let(:webhook_url) { 'http://alerts.test/hook' }
  let(:miner_id) { '10.0.0.5:4028' }

  let(:config) do
    CgminerMonitor::Config.from_env(
      'CGMINER_MONITOR_MINERS_FILE' => miners_file_path,
      'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
      'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => webhook_url,
      'CGMINER_MONITOR_ALERTS_WEBHOOK_FORMAT' => 'generic',
      'CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '85',
      'CGMINER_MONITOR_ALERTS_COOLDOWN_SECONDS' => '60',
      'CGMINER_MONITOR_ALERTS_WEBHOOK_TIMEOUT_SECONDS' => '2'
    )
  end

  let(:evaluator) { CgminerMonitor::AlertEvaluator.new(config) }

  before do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
    stub_request(:post, webhook_url).to_return(status: 200)
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

  it 'runs a fired -> resolved cycle end-to-end' do
    # Tick 1: temperature over threshold -> fire
    upsert_snapshot(miner: miner_id, command: 'devs',
                    response: { 'DEVS' => [{ 'Temperature' => 92.0 }] })
    evaluator.evaluate(Time.now.utc)

    state = CgminerMonitor::AlertState.find("#{miner_id}|temperature_above")
    expect(state.state).to eq 'violating'
    expect(WebMock).to have_requested(:post, webhook_url).once
    fired_body = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.body)
    expect(fired_body['event']).to eq 'alert.fired'

    # Tick 2: temperature back to normal -> resolve
    WebMock.reset_executed_requests!
    upsert_snapshot(miner: miner_id, command: 'devs',
                    response: { 'DEVS' => [{ 'Temperature' => 70.0 }] })
    evaluator.evaluate(Time.now.utc)

    state.reload
    expect(state.state).to eq 'ok'
    expect(WebMock).to have_requested(:post, webhook_url).once
    resolved_body = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.body)
    expect(resolved_body['event']).to eq 'alert.resolved'
  end

  it 're-fires alert.fired after cooldown elapses while still violating' do
    upsert_snapshot(miner: miner_id, command: 'devs',
                    response: { 'DEVS' => [{ 'Temperature' => 92.0 }] })

    # Tick 1: first fire.
    first_tick = Time.now.utc - 120
    evaluator.evaluate(first_tick)
    expect(WebMock).to have_requested(:post, webhook_url).once

    # Tick 2: still violating, but cooldown elapsed (60s default, 120s between ticks).
    WebMock.reset_executed_requests!
    evaluator.evaluate(Time.now.utc)

    expect(WebMock).to have_requested(:post, webhook_url).once
    state = CgminerMonitor::AlertState.find("#{miner_id}|temperature_above")
    expect(state.state).to eq 'violating'
    expect(state.last_fired_at).to be_within(5).of(Time.now.utc)
  end

  it 'does not re-fire when cooldown has not elapsed' do
    upsert_snapshot(miner: miner_id, command: 'devs',
                    response: { 'DEVS' => [{ 'Temperature' => 92.0 }] })

    now = Time.now.utc
    evaluator.evaluate(now)
    WebMock.reset_executed_requests!

    # Tick 2: 10s later, still violating, still inside the 60s cooldown.
    evaluator.evaluate(now + 10)
    expect(WebMock).not_to have_requested(:post, webhook_url)
  end
end
