# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::SampleQuery do
  let(:now) { Time.utc(2026, 4, 15, 12, 0, 0) }
  let(:miner_a) { '10.0.0.5:4028' }
  let(:miner_b) { '10.0.0.7:4028' }

  describe '.hashrate' do
    before do
      # Two miners, two timestamps, summary metrics
      %w[ghs_5s ghs_av device_hardware_pct device_rejected_pct pool_rejected_pct
         pool_stale_pct].each_with_index do |metric, i|
        insert_samples(
          build_sample(miner: miner_a, command: 'summary', metric: metric, value: (i + 1) * 10.0, ts: now),
          build_sample(miner: miner_b, command: 'summary', metric: metric, value: (i + 1) * 5.0, ts: now)
        )
      end
    end

    context 'for a single miner' do
      it 'returns hashrate metrics pivoted by timestamp' do
        result = described_class.hashrate(miner: miner_a, since: now - 60, until_: now + 60)

        expect(result.size).to eq 1
        row = result.first
        expect(row[0]).to eq now.to_i         # ts
        expect(row[1]).to eq 10.0             # ghs_5s
        expect(row[2]).to eq 20.0             # ghs_av
      end
    end

    context 'for all miners (aggregate)' do
      it 'sums hashrates and averages error rates' do
        result = described_class.hashrate(since: now - 60, until_: now + 60)

        expect(result.size).to eq 1
        row = result.first
        expect(row[0]).to eq now.to_i
        expect(row[1]).to eq 15.0             # ghs_5s: 10 + 5
        expect(row[2]).to eq 30.0             # ghs_av: 20 + 10
        # device_hardware_pct is averaged: (30 + 15) / 2 = 22.5
        expect(row[3]).to be_within(0.01).of(22.5)
      end
    end
  end

  describe '.temperature' do
    before do
      # Miner A: two devices with temps
      insert_samples(
        build_sample(miner: miner_a, command: 'devs', sub: 0, metric: 'temperature', value: 60.0, ts: now),
        build_sample(miner: miner_a, command: 'devs', sub: 1, metric: 'temperature', value: 70.0, ts: now)
      )
    end

    context 'for a single miner' do
      it 'returns min, avg, max temperature per timestamp' do
        result = described_class.temperature(miner: miner_a, since: now - 60, until_: now + 60)

        expect(result.size).to eq 1
        row = result.first
        expect(row[0]).to eq now.to_i
        expect(row[1]).to eq 60.0             # min
        expect(row[2]).to eq 65.0             # avg
        expect(row[3]).to eq 70.0             # max
      end
    end

    context 'for all miners (aggregate)' do
      before do
        insert_samples(
          build_sample(miner: miner_b, command: 'devs', sub: 0, metric: 'temperature', value: 80.0, ts: now)
        )
      end

      it 'aggregates temperatures across all miners' do
        result = described_class.temperature(since: now - 60, until_: now + 60)

        row = result.first
        expect(row[1]).to eq 60.0             # min across all
        expect(row[2]).to be_within(0.01).of(70.0) # avg: (60+70+80)/3
        expect(row[3]).to eq 80.0 # max across all
      end
    end
  end

  describe '.availability' do
    before do
      # Two miners polled twice: first poll both ok, second poll miner_b fails
      insert_samples(
        build_sample(miner: miner_a, command: 'poll', metric: 'ok', value: 1, ts: now),
        build_sample(miner: miner_b, command: 'poll', metric: 'ok', value: 1, ts: now),
        build_sample(miner: miner_a, command: 'poll', metric: 'ok', value: 1, ts: now + 60),
        build_sample(miner: miner_b, command: 'poll', metric: 'ok', value: 0, ts: now + 60)
      )
    end

    context 'for a single miner' do
      it 'returns per-poll availability as [ts, 0|1]' do
        result = described_class.availability(miner: miner_a, since: now - 60, until_: now + 120)
        expect(result).to eq [[now.to_i, 1], [(now + 60).to_i, 1]]
      end
    end

    context 'for all miners (aggregate)' do
      it 'returns [ts, available_count, configured_count]' do
        # Need snapshots to determine configured count
        upsert_snapshot(miner: miner_a, command: 'summary', fetched_at: now)
        upsert_snapshot(miner: miner_b, command: 'summary', fetched_at: now)

        result = described_class.availability(since: now - 60, until_: now + 120)
        expect(result.size).to eq 2
        expect(result[0]).to eq [now.to_i, 2, 2]          # both available
        expect(result[1]).to eq [(now + 60).to_i, 1, 2]   # one failed
      end
    end
  end
end
