# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::AlertState do
  let(:miner) { '10.0.0.5:4028' }
  let(:rule)  { 'thermal_stress' }

  describe '#last_observed_components round-trip' do
    it 'persists a string-keyed Float-valued hash and re-reads it intact (fresh fetch)' do
      doc = described_class.new(miner: miner, rule: rule, state: 'violating',
                                threshold: nil, last_observed: nil,
                                last_observed_components: { 'ghs_5s' => 450.5, 'temp_max' => 82.3 },
                                last_fired_at: Time.now.utc, last_transition_at: Time.now.utc)
      doc.save!

      # Force a fresh fetch — Mongoid's in-memory hash isn't proof of round-trip.
      reloaded = described_class.find(described_class.composite_id(miner, rule))
      expect(reloaded.last_observed_components).to eq('ghs_5s' => 450.5, 'temp_max' => 82.3)
    end

    it 'leaves last_observed_components nil for built-in-rule docs (backward-compat default)' do
      doc = described_class.new(miner: miner, rule: 'temperature_above', state: 'violating',
                                threshold: 80.0, last_observed: 82.0,
                                last_fired_at: Time.now.utc, last_transition_at: Time.now.utc)
      doc.save!

      reloaded = described_class.find(described_class.composite_id(miner, 'temperature_above'))
      expect(reloaded.last_observed_components).to be_nil
    end

    it 'tolerates Symbol-keyed hashes by coercing keys to strings on read (Mongoid + BSON behavior)' do
      # Defensive: if a future caller forgets to pre-stringify, what comes back from Mongo?
      # We pin the actual behavior so a regression surfaces here, not at webhook fire time.
      doc = described_class.new(miner: miner, rule: rule, state: 'violating',
                                last_observed_components: { ghs_5s: 450.5, temp_max: 82.3 },
                                last_fired_at: Time.now.utc, last_transition_at: Time.now.utc)
      doc.save!

      reloaded = described_class.find(described_class.composite_id(miner, rule))
      # BSON serializes Symbol keys to Strings on the wire — verify what we actually get back.
      keys = reloaded.last_observed_components.keys
      expect(keys.all?(String)).to be(true), "expected all string keys, got: #{keys.map(&:class)}"
    end
  end
end
