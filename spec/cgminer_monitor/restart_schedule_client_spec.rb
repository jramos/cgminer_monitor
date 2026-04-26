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
