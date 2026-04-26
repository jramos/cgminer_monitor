# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

RSpec.describe CgminerMonitor::RestartScheduleClient do
  let(:url) { 'http://manager.local:3000/api/v1/restart_schedules.json' }
  let(:grace) { 300 }
  let(:client) { described_class.new(url: url, grace_seconds: grace, cache_seconds: 30) }

  let(:enabled_payload) do
    {
      'schedules' => [
        {
          'miner_id' => '127.0.0.1:4028',
          'enabled' => true,
          'time_utc' => '04:00',
          'last_restart_at' => nil,
          'last_scheduled_date_utc' => nil
        }
      ],
      'generated_at' => '2026-04-24T04:00:30Z'
    }
  end

  before do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  after do
    WebMock.reset!
    WebMock.disable!
  end

  describe '#in_restart_window?' do
    before do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(enabled_payload))
    end

    it 'returns true when now is at the scheduled minute' do
      now = Time.utc(2026, 4, 24, 4, 0, 30)
      expect(client.in_restart_window?('127.0.0.1:4028', now)).to be(true)
    end

    it 'returns true within the grace window' do
      now = Time.utc(2026, 4, 24, 4, 4, 59) # 4 min 59 s after, < 5 min grace
      expect(client.in_restart_window?('127.0.0.1:4028', now)).to be(true)
    end

    it 'returns false after grace expires' do
      now = Time.utc(2026, 4, 24, 4, 5, 1)
      expect(client.in_restart_window?('127.0.0.1:4028', now)).to be(false)
    end

    it 'returns false before the scheduled minute (one-sided window)' do
      now = Time.utc(2026, 4, 24, 3, 59, 30)
      expect(client.in_restart_window?('127.0.0.1:4028', now)).to be(false)
    end

    it 'handles midnight wrap (schedule 23:59, grace 300s, now 00:02 UTC)' do
      payload = enabled_payload.dup
      payload['schedules'] = [payload['schedules'].first.merge('time_utc' => '23:59')]
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(payload))

      now = Time.utc(2026, 4, 25, 0, 2, 0)
      expect(client.in_restart_window?('127.0.0.1:4028', now)).to be(true)
    end

    it 'returns false for miners not in the schedule list' do
      now = Time.utc(2026, 4, 24, 4, 0, 30)
      expect(client.in_restart_window?('10.0.0.99:4028', now)).to be(false)
    end

    it 'returns false for disabled schedules' do
      payload = enabled_payload.dup
      payload['schedules'] = [payload['schedules'].first.merge('enabled' => false)]
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(payload))

      now = Time.utc(2026, 4, 24, 4, 0, 30)
      expect(client.in_restart_window?('127.0.0.1:4028', now)).to be(false)
    end
  end

  describe '#in_drain? (v1.5.0+)' do
    let(:drained_payload) do
      enabled_payload.merge(
        'schedules' => [
          enabled_payload['schedules'].first.merge(
            'drained' => true,
            'drained_at' => '2026-04-26T12:00:00.000Z',
            'drained_by' => 'operator'
          )
        ]
      )
    end

    let(:not_drained_payload) do
      enabled_payload.merge(
        'schedules' => [
          enabled_payload['schedules'].first.merge('drained' => false, 'drained_at' => nil)
        ]
      )
    end

    let(:now) { Time.utc(2026, 4, 26, 12, 5, 0) }

    it 'returns true for a drained miner' do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(drained_payload))
      expect(client.in_drain?('127.0.0.1:4028', now)).to be(true)
    end

    it 'returns false for a not-drained miner' do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(not_drained_payload))
      expect(client.in_drain?('127.0.0.1:4028', now)).to be(false)
    end

    it 'returns false when the drained field is absent (back-compat with pre-v1.8.0 manager)' do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(enabled_payload))
      expect(client.in_drain?('127.0.0.1:4028', now)).to be(false)
    end

    it 'returns false when drained is exactly true but drained_at is malformed' do
      payload = enabled_payload.merge(
        'schedules' => [enabled_payload['schedules'].first.merge('drained' => true,
                                                                 'drained_at' => 'not-a-timestamp')]
      )
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(payload))
      expect(client.in_drain?('127.0.0.1:4028', now)).to be(false)
    end

    it 'returns false when drained is exactly true but drained_at is missing' do
      payload = enabled_payload.merge(
        'schedules' => [enabled_payload['schedules'].first.merge('drained' => true)]
      )
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(payload))
      expect(client.in_drain?('127.0.0.1:4028', now)).to be(false)
    end

    it 'returns false when drained is truthy-but-not-true (defensive — only exact `true` counts)' do
      payload = enabled_payload.merge(
        'schedules' => [enabled_payload['schedules'].first.merge('drained' => 'true',
                                                                 'drained_at' => '2026-04-26T12:00:00Z')]
      )
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(payload))
      expect(client.in_drain?('127.0.0.1:4028', now)).to be(false)
    end

    it 'returns false for unknown miners' do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(drained_payload))
      expect(client.in_drain?('10.0.0.99:4028', now)).to be(false)
    end

    it 'fails open on manager fetch failure (returns false, not crash)' do
      stub_request(:get, url).to_raise(Errno::ECONNREFUSED)
      CgminerMonitor::Logger.output = StringIO.new
      CgminerMonitor::Logger.level = 'error'
      expect(client.in_drain?('127.0.0.1:4028', now)).to be(false)
    ensure
      CgminerMonitor::Logger.output = $stdout
      CgminerMonitor::Logger.level = 'info'
    end
  end

  describe 'caching' do
    it 'does not re-hit the network within cache_seconds' do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(enabled_payload))
      now = Time.utc(2026, 4, 24, 4, 0, 30)

      5.times { client.in_restart_window?('127.0.0.1:4028', now) }
      expect(WebMock).to have_requested(:get, url).once
    end
  end

  describe 'failure modes (fail-open: empty map, log once, keep going)' do
    it 'returns false on HTTP timeout and logs restart.schedule_fetch_failed' do
      stub_request(:get, url).to_timeout
      allow(CgminerMonitor::Logger).to receive(:warn)

      result = client.in_restart_window?('127.0.0.1:4028', Time.utc(2026, 4, 24, 4, 0, 30))
      expect(result).to be(false)
      expect(CgminerMonitor::Logger).to have_received(:warn).with(
        hash_including(event: 'restart.schedule_fetch_failed')
      )
    end

    it 'returns false on HTTP 500' do
      stub_request(:get, url).to_return(status: 500, body: 'oops')
      allow(CgminerMonitor::Logger).to receive(:warn)

      result = client.in_restart_window?('127.0.0.1:4028', Time.utc(2026, 4, 24, 4, 0, 30))
      expect(result).to be(false)
      expect(CgminerMonitor::Logger).to have_received(:warn).with(
        hash_including(event: 'restart.schedule_fetch_failed')
      )
    end

    it 'returns false on malformed JSON' do
      stub_request(:get, url).to_return(status: 200, body: '{not json')
      allow(CgminerMonitor::Logger).to receive(:warn)

      result = client.in_restart_window?('127.0.0.1:4028', Time.utc(2026, 4, 24, 4, 0, 30))
      expect(result).to be(false)
      expect(CgminerMonitor::Logger).to have_received(:warn).with(
        hash_including(event: 'restart.schedule_fetch_failed', error: 'JSON::ParserError')
      )
    end

    it 'returns false when the response is missing the schedules key' do
      stub_request(:get, url).to_return(status: 200, body: JSON.generate(other: 'unrelated'))
      allow(CgminerMonitor::Logger).to receive(:warn)

      result = client.in_restart_window?('127.0.0.1:4028', Time.utc(2026, 4, 24, 4, 0, 30))
      expect(result).to be(false)
    end
  end
end
