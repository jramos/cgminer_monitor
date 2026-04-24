# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::AlertEvaluator do
  subject(:evaluator) { described_class.new(config, webhook_client: webhook_client) }

  let(:webhook_client) { double('WebhookClient', fire: nil) }
  let(:miners_file_path) do
    path = File.expand_path('../../tmp/test_evaluator_miners.yml', __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "- host: 10.0.0.5\n  port: 4028\n")
    path
  end

  let(:miner_id) { '10.0.0.5:4028' }
  let(:now) { Time.now.utc }

  let(:base_env) do
    {
      'CGMINER_MONITOR_MINERS_FILE' => miners_file_path,
      'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
      'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'http://example.com/hook',
      'CGMINER_MONITOR_ALERTS_COOLDOWN_SECONDS' => '300'
    }
  end

  def make_config(extra = {})
    CgminerMonitor::Config.from_env(base_env.merge(extra))
  end

  before do
    CgminerMonitor::Logger.output = StringIO.new
    CgminerMonitor::Logger.level = 'error'
  end

  after do
    CgminerMonitor::Logger.output = $stdout
    CgminerMonitor::Logger.level = 'info'
    FileUtils.rm_f(miners_file_path)
  end

  describe 'when alerts_enabled=false' do
    let(:config) do
      CgminerMonitor::Config.from_env('CGMINER_MONITOR_MINERS_FILE' => miners_file_path)
    end

    it 'early-returns without reading Snapshot or writing AlertState' do
      upsert_snapshot(miner: miner_id, command: 'summary',
                      response: { 'SUMMARY' => [{ 'GHS 5s' => 1.0 }] })

      expect(CgminerMonitor::Snapshot).not_to receive(:where)
      evaluator.evaluate(now)

      expect(CgminerMonitor::AlertState.count).to eq 0
      expect(webhook_client).not_to have_received(:fire)
    end
  end

  describe 'hashrate_below rule' do
    let(:config) { make_config('CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS' => '1000') }

    context 'when observed >= threshold (healthy, no prior doc)' do
      before do
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 1500.0 }] })
      end

      it 'creates an ok state doc and does not fire' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below")
        expect(state.state).to eq 'ok'
        expect(state.last_observed).to eq 1500.0
        expect(state.threshold).to eq 1000.0
        expect(webhook_client).not_to have_received(:fire)
      end
    end

    context 'when observed < threshold, no prior doc (first-ever observation)' do
      before do
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 500.0 }] })
      end

      it 'emits alert.fired and persists state=violating with last_fired_at' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below")
        expect(state.state).to eq 'violating'
        expect(state.last_fired_at).to be_within(1).of(now)
        expect(state.last_transition_at).to be_within(1).of(now)
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.fired', miner: miner_id, rule: 'hashrate_below',
                         observed: 500.0, threshold: 1000.0, unit: 'GH/s')
        )
      end
    end

    context 'when ok -> violating transition' do
      before do
        CgminerMonitor::AlertState.create!(miner: miner_id, rule: 'hashrate_below',
                                           state: 'ok', threshold: 1000.0,
                                           last_observed: 1500.0,
                                           last_transition_at: now - 600)
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 500.0 }] })
      end

      it 'emits alert.fired once and flips state to violating' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below")
        expect(state.state).to eq 'violating'
        expect(webhook_client).to have_received(:fire).once.with(
          hash_including(event: 'alert.fired')
        )
      end
    end

    context 'when violating -> healthy transition' do
      before do
        CgminerMonitor::AlertState.create!(miner: miner_id, rule: 'hashrate_below',
                                           state: 'violating', threshold: 1000.0,
                                           last_observed: 500.0,
                                           last_fired_at: now - 120,
                                           last_transition_at: now - 120)
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 1500.0 }] })
      end

      it 'emits alert.resolved and flips state to ok' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below")
        expect(state.state).to eq 'ok'
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.resolved', observed: 1500.0, threshold: 1000.0)
        )
      end
    end

    context 'when violating -> violating (cooldown not elapsed)' do
      before do
        CgminerMonitor::AlertState.create!(miner: miner_id, rule: 'hashrate_below',
                                           state: 'violating', threshold: 1000.0,
                                           last_observed: 500.0,
                                           last_fired_at: now - 60,
                                           last_transition_at: now - 60)
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 500.0 }] })
      end

      it 'does not re-fire and preserves last_fired_at' do
        original_last_fired = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below").last_fired_at
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below")
        expect(state.state).to eq 'violating'
        expect(state.last_fired_at).to be_within(1).of(original_last_fired)
        expect(webhook_client).not_to have_received(:fire)
      end
    end

    context 'when violating -> violating (cooldown elapsed)' do
      before do
        CgminerMonitor::AlertState.create!(miner: miner_id, rule: 'hashrate_below',
                                           state: 'violating', threshold: 1000.0,
                                           last_observed: 500.0,
                                           last_fired_at: now - 400,
                                           last_transition_at: now - 600)
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 500.0 }] })
      end

      it 're-fires alert.fired and updates last_fired_at' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below")
        expect(state.last_fired_at).to be_within(1).of(now)
        expect(webhook_client).to have_received(:fire).with(hash_including(event: 'alert.fired'))
      end
    end

    context 'when ok -> ok (no transition)' do
      before do
        CgminerMonitor::AlertState.create!(miner: miner_id, rule: 'hashrate_below',
                                           state: 'ok', threshold: 1000.0,
                                           last_observed: 1400.0,
                                           last_transition_at: now - 600)
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 1500.0 }] })
      end

      it 'is a no-op write-wise (no rewrite) and no fire' do
        transition_before = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below").last_transition_at
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below")
        expect(state.last_transition_at).to be_within(1).of(transition_before)
        expect(webhook_client).not_to have_received(:fire)
      end
    end

    context 'when snapshot has no parseable hashrate' do
      before do
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 'n/a' }] })
      end

      it 'skips evaluation (reading is nil)' do
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.count).to eq 0
        expect(webhook_client).not_to have_received(:fire)
      end
    end

    # Defensive shape-guards: one malformed miner response must never
    # poison the evaluator's tick for other miners. Pre-fix each of
    # these would raise TypeError, unwind into Poller's rescue, and
    # skip alert evaluation for every other rig on the fleet.
    context 'malformed SUMMARY shapes' do
      it 'returns nil when SUMMARY is missing' do
        upsert_snapshot(miner: miner_id, command: 'summary', response: {})
        expect { evaluator.evaluate(now) }.not_to raise_error
        expect(webhook_client).not_to have_received(:fire)
      end

      it 'returns nil when SUMMARY is a Hash instead of Array' do
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => { 'GHS 5s' => 500 } })
        expect { evaluator.evaluate(now) }.not_to raise_error
        expect(webhook_client).not_to have_received(:fire)
      end

      it 'returns nil when SUMMARY first entry is not a Hash' do
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => ['stringified'] })
        expect { evaluator.evaluate(now) }.not_to raise_error
        expect(webhook_client).not_to have_received(:fire)
      end

      it 'returns nil when response is nil' do
        upsert_snapshot(miner: miner_id, command: 'summary', ok: true, response: nil)
        expect { evaluator.evaluate(now) }.not_to raise_error
      end
    end
  end

  describe 'temperature_above rule' do
    let(:config) { make_config('CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '85') }

    context 'when any device temp > threshold' do
      before do
        upsert_snapshot(miner: miner_id, command: 'devs',
                        response: { 'DEVS' => [
                          { 'Temperature' => 70.0 },
                          { 'Temperature' => 92.5 }
                        ] })
      end

      it 'fires on max-over-devices exceeding threshold' do
        evaluator.evaluate(now)
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.fired', rule: 'temperature_above',
                         observed: 92.5, threshold: 85.0, unit: 'C')
        )
      end
    end

    context 'when all device temps <= threshold' do
      before do
        upsert_snapshot(miner: miner_id, command: 'devs',
                        response: { 'DEVS' => [{ 'Temperature' => 70.0 }, { 'Temperature' => 85.0 }] })
      end

      it 'does not fire (boundary: equal-to is healthy)' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|temperature_above")
        expect(state.state).to eq 'ok'
        expect(webhook_client).not_to have_received(:fire)
      end
    end

    context 'malformed DEVS shapes' do
      it 'returns nil when DEVS is missing' do
        upsert_snapshot(miner: miner_id, command: 'devs', response: {})
        expect { evaluator.evaluate(now) }.not_to raise_error
        expect(webhook_client).not_to have_received(:fire)
      end

      it 'returns nil when DEVS is a Hash instead of Array' do
        upsert_snapshot(miner: miner_id, command: 'devs',
                        response: { 'DEVS' => { 'Temperature' => 100 } })
        expect { evaluator.evaluate(now) }.not_to raise_error
      end

      it 'returns nil when DEVS is empty' do
        upsert_snapshot(miner: miner_id, command: 'devs', response: { 'DEVS' => [] })
        expect { evaluator.evaluate(now) }.not_to raise_error
      end

      it 'filters out non-Hash entries and uses the max of the rest' do
        upsert_snapshot(miner: miner_id, command: 'devs',
                        response: { 'DEVS' => ['junk', { 'Temperature' => 95 }, nil] })
        evaluator.evaluate(now)
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.fired', rule: 'temperature_above', observed: 95.0)
        )
      end
    end
  end

  describe 'offline rule' do
    let(:config) { make_config('CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS' => '600') }

    # Seeds a Snapshot (for the miners list) and a matching poll/ok
    # Sample row (which drives last_ok_at_per_miner). Mirrors the
    # Poller's write pattern: both collections get touched per tick.
    def seed_poll(at:, ok: true)
      upsert_snapshot(miner: miner_id, command: 'summary', ok: ok,
                      response: ok ? { 'SUMMARY' => [{ 'GHS 5s' => 1000 }] } : nil,
                      error: ok ? nil : 'refused', fetched_at: at)
      insert_samples(build_sample(miner: miner_id, command: 'poll', metric: 'ok',
                                  value: ok ? 1.0 : 0.0, ts: at))
    end

    context 'when last ok is older than threshold' do
      before { seed_poll(at: now - 900, ok: true) }

      it 'fires offline' do
        evaluator.evaluate(now)
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.fired', rule: 'offline', unit: 'seconds')
        )
      end
    end

    # Regression guard for PR review's Critical #1: Poller upserts
    # Snapshot.fetched_at = now on every tick regardless of ok, so the
    # offline rule MUST key on the `poll/ok=1.0` Sample history, not
    # Snapshot.fetched_at.
    context 'when recent poll failed but the last ok Sample is old' do
      before do
        # Poller behavior: every tick upserts the (miner, command) snapshot,
        # so fetched_at advances even when ok=false.
        seed_poll(at: now - 900, ok: true)
        upsert_snapshot(miner: miner_id, command: 'summary', ok: false,
                        error: 'refused', fetched_at: now - 5)
        insert_samples(build_sample(miner: miner_id, command: 'poll', metric: 'ok',
                                    value: 0.0, ts: now - 5))
      end

      it 'still fires offline (keyed on last ok Sample, not latest Snapshot)' do
        evaluator.evaluate(now)
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.fired', rule: 'offline', unit: 'seconds')
        )
      end
    end

    context 'when miner has never succeeded, only failed' do
      before { seed_poll(at: now - 900, ok: false) }

      it 'fires offline with a finite observed value (falls back to first-ever poll sample)' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|offline")
        expect(state.state).to eq 'violating'
        expect(state.last_observed).to be_within(1).of(900)
      end
    end

    context 'when latest poll is ok and recent' do
      before { seed_poll(at: now - 30, ok: true) }

      it 'treats miner as not offline' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|offline")
        expect(state.state).to eq 'ok'
      end
    end

    # N-1 / N / N+1 boundary (>=)
    context 'boundary around offline_after_seconds=600' do
      it 'does not fire at 599 seconds (below boundary)' do
        seed_poll(at: now - 599, ok: true)
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.find("#{miner_id}|offline").state).to eq 'ok'
      end

      it 'fires at exactly 600 seconds (boundary is inclusive via >=)' do
        seed_poll(at: now - 600, ok: true)
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.find("#{miner_id}|offline").state).to eq 'violating'
      end

      it 'fires at 601 seconds (above boundary)' do
        seed_poll(at: now - 601, ok: true)
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.find("#{miner_id}|offline").state).to eq 'violating'
      end
    end
  end

  describe 'alert.evaluation_complete' do
    let(:config) { make_config('CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS' => '1000') }
    let(:log_io) { StringIO.new }

    before do
      upsert_snapshot(miner: miner_id, command: 'summary',
                      response: { 'SUMMARY' => [{ 'GHS 5s' => 500 }] })
      CgminerMonitor::Logger.level = 'info'
      CgminerMonitor::Logger.output = log_io
    end

    it 'emits one evaluation_complete log per tick with duration + counts' do
      evaluator.evaluate(now)
      lines = log_io.string.lines.map { |l| JSON.parse(l) }
      completion = lines.find { |l| l['event'] == 'alert.evaluation_complete' }
      expect(completion).not_to be_nil
      expect(completion['rules_evaluated']).to eq 1
      expect(completion['fired_count']).to eq 1
      expect(completion['resolved_count']).to eq 0
      expect(completion['duration_ms']).to be_a Numeric
    end
  end
end
