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
    def seed_poll(at_time:, ok: true)
      upsert_snapshot(miner: miner_id, command: 'summary', ok: ok,
                      response: ok ? { 'SUMMARY' => [{ 'GHS 5s' => 1000 }] } : nil,
                      error: ok ? nil : 'refused', fetched_at: at_time)
      insert_samples(build_sample(miner: miner_id, command: 'poll', metric: 'ok',
                                  value: ok ? 1.0 : 0.0, ts: at_time))
    end

    context 'when last ok is older than threshold' do
      before { seed_poll(at_time: now - 900, ok: true) }

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
        seed_poll(at_time: now - 900, ok: true)
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
      before { seed_poll(at_time: now - 900, ok: false) }

      it 'fires offline with a finite observed value (falls back to first-ever poll sample)' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|offline")
        expect(state.state).to eq 'violating'
        expect(state.last_observed).to be_within(1).of(900)
      end
    end

    context 'when latest poll is ok and recent' do
      before { seed_poll(at_time: now - 30, ok: true) }

      it 'treats miner as not offline' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.find("#{miner_id}|offline")
        expect(state.state).to eq 'ok'
      end
    end

    context 'with a restart_schedule_client reporting the miner is in its window' do
      let(:restart_schedule_client) do
        instance_double(CgminerMonitor::RestartScheduleClient,
                        in_restart_window?: true, in_drain?: false)
      end
      let(:evaluator) do
        described_class.new(config,
                            webhook_client: webhook_client,
                            restart_schedule_client: restart_schedule_client)
      end

      before { seed_poll(at_time: now - 900, ok: true) }

      it 'does not fire offline (suppressed during scheduled restart window)' do
        evaluator.evaluate(now)
        expect(webhook_client).not_to have_received(:fire).with(
          hash_including(rule: 'offline')
        )
      end

      it 'does not transition AlertState into violating' do
        evaluator.evaluate(now)
        state = CgminerMonitor::AlertState.where(_id: "#{miner_id}|offline").first
        expect(state).to be_nil
      end

      it 'leaves other rules unaffected' do
        # Hashrate rule should still fire if its threshold is breached.
        # Configure a hashrate threshold higher than the seeded value.
        config_with_hashrate = make_config(
          'CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS' => '600',
          'CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS' => '5000'
        )
        # Re-seed snapshot with low hashrate.
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 1000 }] })
        evaluator = described_class.new(config_with_hashrate,
                                        webhook_client: webhook_client,
                                        restart_schedule_client: restart_schedule_client)
        evaluator.evaluate(now)
        expect(webhook_client).to have_received(:fire).with(
          hash_including(rule: 'hashrate_below')
        )
      end

      it 'emits one suppression log per rule that consumes offline_seconds (built-in + composites)' do
        log_io = StringIO.new
        CgminerMonitor::Logger.output = log_io
        CgminerMonitor::Logger.level = 'info'

        composite_config = make_config(
          'CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS' => '600',
          'CGMINER_MONITOR_ALERTS_COMPOSITE_COLD_DEAD' => 'ghs_5s<100 & offline_seconds>60'
        )
        evaluator = described_class.new(composite_config,
                                        webhook_client: webhook_client,
                                        restart_schedule_client: restart_schedule_client)
        evaluator.evaluate(now)

        suppression_lines = log_io.string.lines.map { |l| JSON.parse(l) }
                                               .select { |l| l['event'] == 'alert.suppressed_during_restart_window' }
        rules = suppression_lines.map { |l| l['rule'] }
        expect(rules).to contain_exactly('offline', 'cold_dead')
        # v1.5.0+: every suppression event carries a `cause:` discriminator.
        expect(suppression_lines.map { |l| l['cause'] }).to all(eq('restart_window'))
      end

      it 'omits the built-in `offline` suppression row when only composites consume offline_seconds' do
        log_io = StringIO.new
        CgminerMonitor::Logger.output = log_io
        CgminerMonitor::Logger.level = 'info'

        # No CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS — built-in offline rule disabled.
        composite_only_config = CgminerMonitor::Config.from_env(
          base_env.merge(
            'CGMINER_MONITOR_ALERTS_COMPOSITE_COLD_DEAD' => 'ghs_5s<100 & offline_seconds>60'
          )
        )
        evaluator = described_class.new(composite_only_config,
                                        webhook_client: webhook_client,
                                        restart_schedule_client: restart_schedule_client)
        evaluator.evaluate(now)

        suppression_lines = log_io.string.lines.map { |l| JSON.parse(l) }
                                               .select { |l| l['event'] == 'alert.suppressed_during_restart_window' }
        rules = suppression_lines.map { |l| l['rule'] }
        expect(rules).to eq(['cold_dead']) # NOT 'offline' — that built-in is disabled
      end
    end

    context 'with a restart_schedule_client reporting the miner is in DRAIN (v1.5.0+)' do
      let(:restart_schedule_client) do
        instance_double(CgminerMonitor::RestartScheduleClient,
                        in_restart_window?: false, in_drain?: true)
      end
      let(:evaluator) do
        described_class.new(config,
                            webhook_client: webhook_client,
                            restart_schedule_client: restart_schedule_client)
      end

      before { seed_poll(at_time: now - 900, ok: true) }

      it 'suppresses the offline rule with cause: :drain' do
        log_io = StringIO.new
        CgminerMonitor::Logger.output = log_io
        CgminerMonitor::Logger.level = 'info'

        evaluator.evaluate(now)

        suppression_lines = log_io.string.lines.map { |l| JSON.parse(l) }
                                               .select { |l| l['event'] == 'alert.suppressed_during_restart_window' }
        expect(suppression_lines.map { |l| l['cause'] }).to all(eq('drain'))
        expect(webhook_client).not_to have_received(:fire).with(hash_including(rule: 'offline'))
      end

      it 'emits one suppression line per rule consuming offline_seconds (built-in + composite)' do
        log_io = StringIO.new
        CgminerMonitor::Logger.output = log_io
        CgminerMonitor::Logger.level = 'info'

        composite_config = make_config(
          'CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS' => '600',
          'CGMINER_MONITOR_ALERTS_COMPOSITE_COLD_DEAD' => 'ghs_5s<100 & offline_seconds>60'
        )
        evaluator = described_class.new(composite_config,
                                        webhook_client: webhook_client,
                                        restart_schedule_client: restart_schedule_client)
        evaluator.evaluate(now)

        suppression_lines = log_io.string.lines.map { |l| JSON.parse(l) }
                                               .select { |l| l['event'] == 'alert.suppressed_during_restart_window' }
        rules = suppression_lines.map { |l| l['rule'] }
        expect(rules).to contain_exactly('offline', 'cold_dead')
        expect(suppression_lines.map { |l| l['cause'] }).to all(eq('drain'))
      end
    end

    context 'with both in_restart_window? AND in_drain? returning true' do
      let(:restart_schedule_client) do
        instance_double(CgminerMonitor::RestartScheduleClient,
                        in_restart_window?: true, in_drain?: true)
      end
      let(:evaluator) do
        described_class.new(config,
                            webhook_client: webhook_client,
                            restart_schedule_client: restart_schedule_client)
      end

      before { seed_poll(at_time: now - 900, ok: true) }

      it 'logs cause: :restart_window (first-true predicate wins)' do
        log_io = StringIO.new
        CgminerMonitor::Logger.output = log_io
        CgminerMonitor::Logger.level = 'info'

        evaluator.evaluate(now)

        suppression_lines = log_io.string.lines.map { |l| JSON.parse(l) }
                                               .select { |l| l['event'] == 'alert.suppressed_during_restart_window' }
        expect(suppression_lines.map { |l| l['cause'] }).to all(eq('restart_window'))
      end
    end

    context 'with a restart_schedule_client reporting the miner is NOT in its window' do
      let(:restart_schedule_client) do
        instance_double(CgminerMonitor::RestartScheduleClient,
                        in_restart_window?: false, in_drain?: false)
      end
      let(:evaluator) do
        described_class.new(config,
                            webhook_client: webhook_client,
                            restart_schedule_client: restart_schedule_client)
      end

      before { seed_poll(at_time: now - 900, ok: true) }

      it 'fires offline normally' do
        evaluator.evaluate(now)
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.fired', rule: 'offline')
        )
      end
    end

    # N-1 / N / N+1 boundary (>=)
    context 'boundary around offline_after_seconds=600' do
      it 'does not fire at 599 seconds (below boundary)' do
        seed_poll(at_time: now - 599, ok: true)
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.find("#{miner_id}|offline").state).to eq 'ok'
      end

      it 'fires at exactly 600 seconds (boundary is inclusive via >=)' do
        seed_poll(at_time: now - 600, ok: true)
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.find("#{miner_id}|offline").state).to eq 'violating'
      end

      it 'fires at 601 seconds (above boundary)' do
        seed_poll(at_time: now - 601, ok: true)
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.find("#{miner_id}|offline").state).to eq 'violating'
      end
    end
  end

  describe 'state persistence across evaluator instances (restart)' do
    let(:config) { make_config('CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS' => '1000') }

    before do
      upsert_snapshot(miner: miner_id, command: 'summary',
                      response: { 'SUMMARY' => [{ 'GHS 5s' => 500 }] })
    end

    it 'resumes a violating state from Mongo and re-fires after cooldown' do
      # Seed state as if a prior monitor process saved it before restart.
      CgminerMonitor::AlertState.create!(miner: miner_id, rule: 'hashrate_below',
                                         state: 'violating', threshold: 1000.0,
                                         last_observed: 500.0,
                                         last_fired_at: now - 400,
                                         last_transition_at: now - 600)

      # Fresh evaluator instance — mimics "new monitor process after restart."
      fresh = described_class.new(config, webhook_client: webhook_client)
      fresh.evaluate(now)

      expect(webhook_client).to have_received(:fire).with(hash_including(event: 'alert.fired'))
      state = CgminerMonitor::AlertState.find("#{miner_id}|hashrate_below")
      expect(state.last_fired_at).to be_within(1).of(now)
    end

    it 'does not re-fire on restart when cooldown has not yet elapsed' do
      CgminerMonitor::AlertState.create!(miner: miner_id, rule: 'hashrate_below',
                                         state: 'violating', threshold: 1000.0,
                                         last_observed: 500.0,
                                         last_fired_at: now - 60,
                                         last_transition_at: now - 120)

      fresh = described_class.new(config, webhook_client: webhook_client)
      fresh.evaluate(now)

      expect(webhook_client).not_to have_received(:fire)
    end
  end

  describe 'partial-rules configuration' do
    let(:config) do
      # Two rules enabled (hashrate + temperature), offline threshold unset.
      make_config('CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS' => '1000',
                  'CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '85')
    end

    before do
      upsert_snapshot(miner: miner_id, command: 'summary',
                      response: { 'SUMMARY' => [{ 'GHS 5s' => 500 }] })
      upsert_snapshot(miner: miner_id, command: 'devs',
                      response: { 'DEVS' => [{ 'Temperature' => 90 }] })
    end

    it 'evaluates only the configured rules; the unset rule is absent from state' do
      evaluator.evaluate(now)

      expect(CgminerMonitor::AlertState.where(_id: "#{miner_id}|hashrate_below").first).not_to be_nil
      expect(CgminerMonitor::AlertState.where(_id: "#{miner_id}|temperature_above").first).not_to be_nil
      expect(CgminerMonitor::AlertState.where(_id: "#{miner_id}|offline").first).to be_nil
    end

    it 'does not issue the Snapshot query for the disabled rule' do
      # Expect devs + summary Snapshot.where(command: X, ok: true) but NOT SnapshotQuery.miners
      # (which is only invoked to drive offline readings).
      expect(CgminerMonitor::SnapshotQuery).not_to receive(:miners)
      evaluator.evaluate(now)
    end
  end

  describe 'composite rules' do
    let(:composite_id_str) { "#{miner_id}|thermal_stress" }

    def composite_config(extra = {})
      make_config({
        'CGMINER_MONITOR_ALERTS_COMPOSITE_THERMAL_STRESS' => 'ghs_5s<500 & temp_max>80'
      }.merge(extra))
    end

    def seed_violating
      upsert_snapshot(miner: miner_id, command: 'summary',
                      response: { 'SUMMARY' => [{ 'GHS 5s' => 450.0 }] })
      upsert_snapshot(miner: miner_id, command: 'devs',
                      response: { 'DEVS' => [{ 'Temperature' => 82.0 }] })
    end

    describe 'fired/resolved lifecycle' do
      let(:config) { composite_config }

      it 'fires alert.fired with composite-shaped threshold/observed/details on first violation' do
        seed_violating
        evaluator.evaluate(now)

        state = CgminerMonitor::AlertState.find(composite_id_str)
        expect(state.state).to eq 'violating'
        expect(state.last_observed).to be_nil # composites use last_observed_components, not Float
        expect(state.last_observed_components).to include('ghs_5s', 'temp_max')

        expect(webhook_client).to have_received(:fire).with(
          hash_including(
            event: 'alert.fired',
            rule: 'thermal_stress',
            threshold: 'ghs_5s<500.0 & temp_max>80.0',
            observed: 'ghs_5s=450.0 temp_max=82.0',
            unit: nil,
            details: hash_including('expression' => 'ghs_5s<500.0 & temp_max>80.0')
          )
        )
      end

      it 'does not re-fire on the next tick (state already violating, cooldown not elapsed)' do
        seed_violating
        evaluator.evaluate(now)
        evaluator.evaluate(now + 30)
        expect(webhook_client).to have_received(:fire).once
      end

      it 'fires alert.resolved when one clause clears (AND semantics → resolution on first clearing)' do
        seed_violating
        evaluator.evaluate(now)

        # Temperature drops to safe — composite resolves even though hashrate still violates.
        upsert_snapshot(miner: miner_id, command: 'devs',
                        response: { 'DEVS' => [{ 'Temperature' => 70.0 }] })
        evaluator.evaluate(now + 30)

        state = CgminerMonitor::AlertState.find(composite_id_str)
        expect(state.state).to eq 'ok'
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.resolved', rule: 'thermal_stress')
        )
      end

      it 're-fires after cooldown elapses while still violating' do
        seed_violating
        evaluator.evaluate(now)
        evaluator.evaluate(now + 301) # cooldown defaults to 300s
        expect(webhook_client).to have_received(:fire).twice.with(
          hash_including(event: 'alert.fired', rule: 'thermal_stress')
        )
      end
    end

    describe 'reading bookkeeping — composite forces atom reads even when built-in is disabled' do
      let(:config) do
        # No CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C set — built-in temp rule disabled,
        # but the composite needs temp_max so the devs snapshot must still be read.
        composite_config
      end

      it 'reads the devs snapshot for temp_max even though temperature_above is unset' do
        seed_violating
        expect(CgminerMonitor::Snapshot).to receive(:where)
          .with(command: 'devs', ok: true).and_call_original
        expect(CgminerMonitor::Snapshot).to receive(:where)
          .with(command: 'summary', ok: true).and_call_original
        evaluator.evaluate(now)
      end
    end

    describe 'missing-atom semantics — skip the tick (NO state write, NO emit)' do
      let(:config) { composite_config }

      it 'does not transition a violating composite to ok when a required snapshot disappears' do
        seed_violating
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.find(composite_id_str).state).to eq 'violating'

        # Wipe the devs snapshot — temp_max becomes unreadable.
        CgminerMonitor::Snapshot.where(miner: miner_id, command: 'devs').delete

        evaluator.evaluate(now + 30)
        # State unchanged; no resolved emitted.
        expect(CgminerMonitor::AlertState.find(composite_id_str).state).to eq 'violating'
        expect(webhook_client).to have_received(:fire).once # the original fire, no resolve
      end

      it 'does not create an ok state doc when a required reading is missing on first sight' do
        upsert_snapshot(miner: miner_id, command: 'summary',
                        response: { 'SUMMARY' => [{ 'GHS 5s' => 450.0 }] })
        # No devs snapshot at all — temp_max is nil.
        evaluator.evaluate(now)
        expect(CgminerMonitor::AlertState.where(_id: composite_id_str).first).to be_nil
      end
    end

    describe 'cooldown asymmetry — fires debounced, resolves emit unconditionally on transition' do
      let(:config) { composite_config }

      it 'can fire→resolve→fire within one cooldown window when conditions flap' do
        # Tick 1: violating → fire
        seed_violating
        evaluator.evaluate(now)
        # Tick 2: temp drops, composite resolves (resolves are NOT debounced)
        upsert_snapshot(miner: miner_id, command: 'devs',
                        response: { 'DEVS' => [{ 'Temperature' => 70.0 }] })
        evaluator.evaluate(now + 30)
        # Tick 3: temp re-rises well before cooldown elapsed (60s < 300s default),
        # composite re-fires — cooldown only debounces violating→violating, and the
        # state is now ok again so the next violation transition fires immediately.
        upsert_snapshot(miner: miner_id, command: 'devs',
                        response: { 'DEVS' => [{ 'Temperature' => 82.0 }] })
        evaluator.evaluate(now + 60)

        expect(webhook_client).to have_received(:fire).exactly(3).times
        expect(webhook_client).to have_received(:fire).twice.with(hash_including(event: 'alert.fired'))
        expect(webhook_client).to have_received(:fire).once.with(hash_including(event: 'alert.resolved'))
      end
    end

    describe 'built-in + composite double-fire on the same observation (intentional)' do
      let(:config) do
        composite_config('CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '80')
      end

      it 'emits alert.fired for BOTH temperature_above and thermal_stress when both apply' do
        seed_violating
        # ghs_5s=450 doesn't trip a hashrate rule (not configured), but temp=82 trips
        # the built-in temperature_above (>80) AND the thermal_stress composite.
        evaluator.evaluate(now)

        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.fired', rule: 'temperature_above')
        )
        expect(webhook_client).to have_received(:fire).with(
          hash_including(event: 'alert.fired', rule: 'thermal_stress')
        )
      end
    end

    describe 'startup config_loaded log line' do
      let(:log_io) { StringIO.new }

      it 'emits one alert.config_loaded line listing built-in rules and composite rule names' do
        CgminerMonitor::Logger.output = log_io
        CgminerMonitor::Logger.level = 'info'

        described_class.new(composite_config('CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '80'),
                            webhook_client: webhook_client)

        loaded = log_io.string.lines.map { |l| JSON.parse(l) }
                                    .find { |l| l['event'] == 'alert.config_loaded' }
        expect(loaded).not_to be_nil
        expect(loaded['built_in_rules']).to eq(['temperature_above'])
        expect(loaded['composite_rules']).to eq(['thermal_stress'])
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
