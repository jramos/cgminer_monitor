# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::Snapshot do
  let(:now) { Time.now.utc }
  let(:miner) { '10.0.0.5:4028' }
  let(:response_hash) { { 'SUMMARY' => [{ 'Elapsed' => 12_345, 'GHS 5s' => 1234.56 }] } }

  describe 'upsert' do
    it 'creates a new document on first upsert' do
      upsert_snapshot(miner: miner, command: 'summary', response: response_hash, fetched_at: now)
      result = described_class.where(miner: miner, command: 'summary').first

      expect(result).not_to be_nil
      expect(result.ok).to be true
      expect(result.response).to eq response_hash
      expect(result.error).to be_nil
    end

    it 'replaces the existing document on subsequent upsert' do
      upsert_snapshot(miner: miner, command: 'summary', response: { 'old' => true }, fetched_at: now - 60)
      upsert_snapshot(miner: miner, command: 'summary', response: response_hash, fetched_at: now)

      expect(described_class.where(miner: miner, command: 'summary').count).to eq 1
      result = described_class.where(miner: miner, command: 'summary').first
      expect(result.response).to eq response_hash
    end

    it 'stores failure state when ok is false' do
      upsert_snapshot(miner: miner, command: 'devs', ok: false, response: nil,
                      error: 'CgminerApiClient::ConnectionError: refused')

      result = described_class.where(miner: miner, command: 'devs').first
      expect(result.ok).to be false
      expect(result.response).to be_nil
      expect(result.error).to eq 'CgminerApiClient::ConnectionError: refused'
    end
  end

  describe 'unique index' do
    it 'enforces one document per (miner, command) pair' do
      upsert_snapshot(miner: miner, command: 'summary', fetched_at: now)
      upsert_snapshot(miner: miner, command: 'devs', fetched_at: now)
      upsert_snapshot(miner: '10.0.0.7:4028', command: 'summary', fetched_at: now)

      expect(described_class.count).to eq 3
    end
  end

  describe 'querying' do
    before do
      upsert_snapshot(miner: miner, command: 'summary', response: response_hash, fetched_at: now)
      upsert_snapshot(miner: miner, command: 'devs', response: { 'DEVS' => [] }, fetched_at: now)
      upsert_snapshot(miner: '10.0.0.7:4028', command: 'summary', ok: false, error: 'refused', fetched_at: now)
    end

    it 'finds by miner' do
      results = described_class.where(miner: miner)
      expect(results.count).to eq 2
    end

    it 'finds by miner and command' do
      result = described_class.where(miner: miner, command: 'summary').first
      expect(result.response).to eq response_hash
    end
  end
end
