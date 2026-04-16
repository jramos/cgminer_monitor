# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::SnapshotQuery do
  let(:now) { Time.now.utc }
  let(:miner_a) { '10.0.0.5:4028' }
  let(:miner_b) { '10.0.0.7:4028' }

  let(:summary_response) { { 'SUMMARY' => [{ 'Elapsed' => 12_345, 'GHS 5s' => 1234.56 }] } }
  let(:devs_response) { { 'DEVS' => [{ 'ASC' => 0, 'Temperature' => 60.5, 'Status' => 'Alive' }] } }
  let(:pools_response) { { 'POOLS' => [{ 'URL' => 'stratum+tcp://pool.example:3333', 'User' => 'worker1' }] } }
  let(:stats_response) { { 'STATS' => [{ 'ID' => 'AntS9', 'temp1' => 60 }] } }

  before do
    upsert_snapshot(miner: miner_a, command: 'summary', response: summary_response, fetched_at: now)
    upsert_snapshot(miner: miner_a, command: 'devs', response: devs_response, fetched_at: now)
    upsert_snapshot(miner: miner_a, command: 'pools', response: pools_response, fetched_at: now)
    upsert_snapshot(miner: miner_a, command: 'stats', response: stats_response, fetched_at: now)
    upsert_snapshot(miner: miner_b, command: 'summary', ok: false, error: 'ConnectionError: refused',
                    fetched_at: now - 120)
  end

  describe '.for_miner' do
    it 'returns the snapshot for a miner and command' do
      result = described_class.for_miner(miner: miner_a, command: 'summary')
      expect(result).not_to be_nil
      expect(result.response).to eq summary_response
      expect(result.ok).to be true
    end

    it 'returns a failed snapshot' do
      result = described_class.for_miner(miner: miner_b, command: 'summary')
      expect(result.ok).to be false
      expect(result.error).to eq 'ConnectionError: refused'
    end

    it 'returns nil for unknown miner' do
      result = described_class.for_miner(miner: '1.2.3.4:4028', command: 'summary')
      expect(result).to be_nil
    end
  end

  describe '.miners' do
    it 'returns distinct miner identifiers with their latest fetched_at and ok status' do
      result = described_class.miners
      expect(result.size).to eq 2
      expect(result.map { |m| m[:miner] }).to contain_exactly(miner_a, miner_b)

      miner_a_info = result.find { |m| m[:miner] == miner_a }
      expect(miner_a_info[:ok]).to be true

      miner_b_info = result.find { |m| m[:miner] == miner_b }
      expect(miner_b_info[:ok]).to be false
    end
  end

  describe '.last_poll_at' do
    it 'returns the most recent fetched_at for a miner' do
      result = described_class.last_poll_at(miner: miner_a)
      expect(result).to be_within(1).of(now)
    end

    it 'returns nil for an unknown miner' do
      result = described_class.last_poll_at(miner: '1.2.3.4:4028')
      expect(result).to be_nil
    end
  end
end
