# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::Sample do
  describe 'time-series collection' do
    it 'creates a time-series collection named samples' do
      assert_time_series_collection!('samples')
    end
  end

  describe 'insert and read roundtrip' do
    let(:now) { Time.now.utc }
    let(:sample_row) do
      build_sample(
        miner: '10.0.0.5:4028',
        command: 'summary',
        sub: 0,
        metric: 'ghs_5s',
        value: 1234.56,
        ts: now
      )
    end

    before { insert_samples(sample_row) }

    it 'persists and retrieves a sample via the Mongoid model' do
      result = described_class.where('meta.miner' => '10.0.0.5:4028').first
      expect(result).not_to be_nil
      expect(result.v).to eq 1234.56
      expect(result.meta['metric']).to eq 'ghs_5s'
      expect(result.meta['command']).to eq 'summary'
    end

    it 'supports querying by time range' do
      results = described_class.where(ts: { '$gte' => now - 60, '$lt' => now + 60 })
      expect(results.count).to eq 1
    end

    it 'supports querying by miner and metric' do
      results = described_class.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.metric' => 'ghs_5s'
      )
      expect(results.count).to eq 1
      expect(results.first.v).to eq 1234.56
    end
  end

  describe 'bulk insert' do
    it 'inserts multiple samples in one call' do
      now = Time.now.utc
      rows = %w[ghs_5s ghs_av].map do |metric|
        build_sample(miner: '10.0.0.5:4028', command: 'summary', metric: metric, value: 100.0, ts: now)
      end

      insert_samples(rows)
      expect(described_class.count).to eq 2
    end
  end
end
