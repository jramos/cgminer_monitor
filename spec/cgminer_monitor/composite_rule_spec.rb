# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::CompositeRule do
  let(:rule) { CgminerMonitor::CompositeRuleParser.parse('thermal_stress', 'ghs_5s<500 & temp_max>80') }

  describe 'parser — happy path' do
    it 'parses a two-clause AND expression' do
      expect(rule.name).to eq('thermal_stress')
      expect(rule.clauses.size).to eq(2)
      metrics = rule.clauses.map { |c| c[:metric] }
      expect(metrics).to contain_exactly('ghs_5s', 'temp_max')
    end

    it 'normalizes whitespace around the AND token and around operators' do
      r = CgminerMonitor::CompositeRuleParser.parse('x', '  ghs_5s   <  500   &   temp_max  >  80  ')
      expect(r.clauses.size).to eq(2)
    end

    it 'recognizes <=, >=, ==, <, > (longest-first matching)' do
      r = CgminerMonitor::CompositeRuleParser.parse('x', 'ghs_5s<=500 & temp_max>=80')
      ops = r.clauses.map { |c| c[:op] }
      expect(ops).to contain_exactly('<=', '>=')
    end
  end

  describe 'parser — rejection paths (one ConfigError per malformed input, listing all problems)' do
    it 'rejects single-clause expressions (a single clause duplicates a built-in rule)' do
      expect { CgminerMonitor::CompositeRuleParser.parse('x', 'ghs_5s<500') }
        .to raise_error(CgminerMonitor::ConfigError, /at least 2 clauses/i)
    end

    it 'rejects unknown metric names' do
      expect { CgminerMonitor::CompositeRuleParser.parse('x', 'foo<500 & temp_max>80') }
        .to raise_error(CgminerMonitor::ConfigError, /unknown metric.*foo/i)
    end

    it 'rejects unknown operators' do
      expect { CgminerMonitor::CompositeRuleParser.parse('x', 'ghs_5s!=500 & temp_max>80') }
        .to raise_error(CgminerMonitor::ConfigError, /operator|clause/i)
    end

    it 'rejects non-numeric thresholds' do
      expect { CgminerMonitor::CompositeRuleParser.parse('x', 'ghs_5s<abc & temp_max>80') }
        .to raise_error(CgminerMonitor::ConfigError, /threshold|abc/i)
    end

    it 'rejects OR (`|`) tokens explicitly' do
      expect { CgminerMonitor::CompositeRuleParser.parse('x', 'ghs_5s<500 | temp_max>80') }
        .to raise_error(CgminerMonitor::ConfigError, /only AND.*&.*supported/i)
    end

    it 'rejects empty expression' do
      expect { CgminerMonitor::CompositeRuleParser.parse('x', '') }
        .to raise_error(CgminerMonitor::ConfigError, /empty/i)
    end

    it 'rejects whitespace-only expression' do
      expect { CgminerMonitor::CompositeRuleParser.parse('x', '   ') }
        .to raise_error(CgminerMonitor::ConfigError, /empty/i)
    end

    it 'aggregates multiple errors into a single ConfigError message' do
      err = nil
      begin
        CgminerMonitor::CompositeRuleParser.parse('x', 'foo<bar & baz!=qux')
      rescue CgminerMonitor::ConfigError => e
        err = e
      end
      expect(err).not_to be_nil
      # Each clause has problems; the aggregated message should reference all of them.
      expect(err.message).to match(/foo/)
      expect(err.message).to match(/baz/)
    end
  end

  describe '#evaluable? — composites skip ticks with any missing required reading' do
    it 'is true when every required atom reading is present' do
      expect(rule.evaluable?('ghs_5s' => 450, 'temp_max' => 82)).to be true
    end

    it 'is false when any required atom reading is nil' do
      expect(rule.evaluable?('ghs_5s' => nil, 'temp_max' => 82)).to be false
      expect(rule.evaluable?('ghs_5s' => 450, 'temp_max' => nil)).to be false
    end

    it 'ignores readings the composite does not reference' do
      readings = { 'ghs_5s' => 450, 'temp_max' => 82, 'offline_seconds' => nil }
      expect(rule.evaluable?(readings)).to be true
    end
  end

  describe '#violates?' do
    it 'is true when every clause violates' do
      expect(rule.violates?('ghs_5s' => 450, 'temp_max' => 82)).to be true
    end

    it 'is false when any one clause does not violate' do
      expect(rule.violates?('ghs_5s' => 600, 'temp_max' => 82)).to be false
      expect(rule.violates?('ghs_5s' => 450, 'temp_max' => 70)).to be false
    end

    it 'raises when called with missing readings (caller must check #evaluable? first)' do
      expect { rule.violates?('ghs_5s' => nil, 'temp_max' => 82) }
        .to raise_error(ArgumentError, /missing reading/i)
    end
  end

  describe 'payload formatting' do
    it 'renders payload_threshold in a canonical, deterministic form (sorted by metric name)' do
      out_of_order = CgminerMonitor::CompositeRuleParser.parse('x', 'temp_max>80 & ghs_5s<500')
      expect(out_of_order.payload_threshold).to eq('ghs_5s<500.0 & temp_max>80.0')
      expect(rule.payload_threshold).to eq('ghs_5s<500.0 & temp_max>80.0')
    end

    it 'round-trips through the parser (parse → payload_threshold → parse → equal canonical form)' do
      first = rule.payload_threshold
      reparsed = CgminerMonitor::CompositeRuleParser.parse('thermal_stress', first)
      expect(reparsed.payload_threshold).to eq(first)
    end

    it 'renders payload_observed as space-separated metric=value pairs (sorted by metric)' do
      expect(rule.payload_observed('ghs_5s' => 450.5, 'temp_max' => 82.3))
        .to eq('ghs_5s=450.5 temp_max=82.3')
    end

    it 'renders payload_details with string-keyed hashes including the canonical expression' do
      details = rule.payload_details('ghs_5s' => 450.5, 'temp_max' => 82.3)
      expect(details['expression']).to eq('ghs_5s<500.0 & temp_max>80.0')
      expect(details['clauses']['ghs_5s']).to eq('observed' => 450.5, 'threshold' => 500.0, 'op' => '<')
      expect(details['clauses']['temp_max']).to eq('observed' => 82.3, 'threshold' => 80.0, 'op' => '>')
    end
  end

  describe 'reserved-name guard' do
    %w[hashrate_below temperature_above offline].each do |reserved|
      it "rejects the reserved built-in name `#{reserved}`" do
        expect { CgminerMonitor::CompositeRuleParser.parse(reserved, 'ghs_5s<500 & temp_max>80') }
          .to raise_error(CgminerMonitor::ConfigError, /collides with a built-in rule/i)
      end
    end
  end
end
