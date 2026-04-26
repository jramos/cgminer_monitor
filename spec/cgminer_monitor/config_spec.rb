# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::Config do
  let(:miners_file) { File.expand_path('../../config/miners.yml.example', __dir__) }
  let(:valid_env) do
    {
      'CGMINER_MONITOR_INTERVAL' => '30',
      'CGMINER_MONITOR_RETENTION_SECONDS' => '86400',
      'CGMINER_MONITOR_MONGO_URL' => 'mongodb://localhost:27017/test_db',
      'CGMINER_MONITOR_HTTP_HOST' => '0.0.0.0',
      'CGMINER_MONITOR_HTTP_PORT' => '8080',
      'CGMINER_MONITOR_HTTP_MIN_THREADS' => '2',
      'CGMINER_MONITOR_HTTP_MAX_THREADS' => '10',
      'CGMINER_MONITOR_MINERS_FILE' => miners_file,
      'CGMINER_MONITOR_LOG_FORMAT' => 'text',
      'CGMINER_MONITOR_LOG_LEVEL' => 'debug',
      'CGMINER_MONITOR_CORS_ORIGINS' => 'http://localhost:3000',
      'CGMINER_MONITOR_SHUTDOWN_TIMEOUT' => '15',
      'CGMINER_MONITOR_HEALTHZ_STALE_MULTIPLIER' => '3',
      'CGMINER_MONITOR_HEALTHZ_STARTUP_GRACE' => '90'
    }
  end

  # Create a minimal miners file for validation
  around do |example|
    unless File.exist?(miners_file)
      FileUtils.mkdir_p(File.dirname(miners_file))
      File.write(miners_file, "- host: 10.0.0.5\n  port: 4028\n")
      @created_miners_file = true
    end
    example.run
  ensure
    File.delete(miners_file) if @created_miners_file && File.exist?(miners_file) # rubocop:disable RSpec/InstanceVariable
  end

  after { described_class.reset! }

  describe '.from_env' do
    it 'parses all env vars into a frozen Config' do
      config = described_class.from_env(valid_env)

      expect(config).to be_frozen
      expect(config.interval).to eq 30
      expect(config.retention_seconds).to eq 86_400
      expect(config.mongo_url).to eq 'mongodb://localhost:27017/test_db'
      expect(config.http_host).to eq '0.0.0.0'
      expect(config.http_port).to eq 8080
      expect(config.http_min_threads).to eq 2
      expect(config.http_max_threads).to eq 10
      expect(config.miners_file).to eq miners_file
      expect(config.log_format).to eq 'text'
      expect(config.log_level).to eq 'debug'
      expect(config.cors_origins).to eq 'http://localhost:3000'
      expect(config.shutdown_timeout).to eq 15
      expect(config.healthz_stale_multiplier).to eq 3
      expect(config.healthz_startup_grace_seconds).to eq 90
    end

    it 'reads CGMINER_MONITOR_PID_FILE when set' do
      config = described_class.from_env(valid_env.merge(
                                          'CGMINER_MONITOR_PID_FILE' => '/tmp/cm-monitor.pid'
                                        ))
      expect(config.pid_file).to eq('/tmp/cm-monitor.pid')
    end

    it 'leaves pid_file nil when CGMINER_MONITOR_PID_FILE unset' do
      config = described_class.from_env(valid_env)
      expect(config.pid_file).to be_nil
    end

    it 'uses sensible defaults when env vars are not set' do
      config = described_class.from_env({ 'CGMINER_MONITOR_MINERS_FILE' => miners_file })

      expect(config.interval).to eq 60
      expect(config.retention_seconds).to eq 30 * 86_400
      expect(config.mongo_url).to eq 'mongodb://localhost:27017/cgminer_monitor'
      expect(config.http_host).to eq '127.0.0.1'
      expect(config.http_port).to eq 9292
      expect(config.http_min_threads).to eq 1
      expect(config.http_max_threads).to eq 5
      expect(config.log_format).to eq 'json'
      expect(config.log_level).to eq 'info'
      expect(config.cors_origins).to eq '*'
      expect(config.shutdown_timeout).to eq 10
      expect(config.healthz_stale_multiplier).to eq 2
      expect(config.healthz_startup_grace_seconds).to eq 60
    end

    it 'raises ConfigError for non-integer interval' do
      env = valid_env.merge('CGMINER_MONITOR_INTERVAL' => 'abc')
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /CGMINER_MONITOR_INTERVAL must be a valid integer/)
    end
  end

  describe '#validate!' do
    it 'raises ConfigError when interval is zero' do
      env = valid_env.merge('CGMINER_MONITOR_INTERVAL' => '0')
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /interval must be > 0/)
    end

    it 'raises ConfigError when interval is negative' do
      env = valid_env.merge('CGMINER_MONITOR_INTERVAL' => '-5')
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /interval must be > 0/)
    end

    it 'raises ConfigError for invalid log_format' do
      env = valid_env.merge('CGMINER_MONITOR_LOG_FORMAT' => 'xml')
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /log_format must be json or text/)
    end

    it 'raises ConfigError for invalid log_level' do
      env = valid_env.merge('CGMINER_MONITOR_LOG_LEVEL' => 'trace')
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /invalid log_level/)
    end

    it 'raises ConfigError when miners_file does not exist' do
      env = valid_env.merge('CGMINER_MONITOR_MINERS_FILE' => '/tmp/nonexistent.yml')
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /miners_file not found/)
    end
  end

  describe 'alerts config' do
    let(:alerts_env) do
      valid_env.merge(
        'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
        'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'https://hooks.slack.com/services/AAA/BBB/CCC',
        'CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '85.0'
      )
    end

    describe 'defaults when alerts_enabled not set' do
      it 'leaves alerts disabled and thresholds nil' do
        config = described_class.from_env(valid_env)
        expect(config.alerts_enabled).to be false
        expect(config.alerts_webhook_url).to be_nil
        expect(config.alerts_webhook_format).to eq 'generic'
        expect(config.alerts_hashrate_min_ghs).to be_nil
        expect(config.alerts_temperature_max_c).to be_nil
        expect(config.alerts_offline_after_seconds).to be_nil
        expect(config.alerts_cooldown_seconds).to eq 300
        expect(config.alerts_webhook_timeout_seconds).to eq 2
      end
    end

    describe 'parse_bool' do
      %w[1 true TRUE yes on].each do |truthy|
        it "accepts #{truthy.inspect} as true" do
          env = valid_env.merge('CGMINER_MONITOR_ALERTS_ENABLED' => truthy)
          # We disable the rest of the alerts validation by only asserting parse succeeded
          # via the next validate pass; use a threshold so validate_alerts! is satisfied.
          env['CGMINER_MONITOR_ALERTS_WEBHOOK_URL'] = 'http://example.com/hook'
          env['CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C'] = '80'
          expect(described_class.from_env(env).alerts_enabled).to be true
        end
      end

      %w[0 false FALSE no off].each do |falsy|
        it "accepts #{falsy.inspect} as false" do
          env = valid_env.merge('CGMINER_MONITOR_ALERTS_ENABLED' => falsy)
          expect(described_class.from_env(env).alerts_enabled).to be false
        end
      end

      it 'raises ConfigError on unparseable bool' do
        env = valid_env.merge('CGMINER_MONITOR_ALERTS_ENABLED' => 'maybe')
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /ALERTS_ENABLED must be a boolean/)
      end
    end

    describe 'parse_optional_float' do
      it 'returns nil when env key unset' do
        config = described_class.from_env(valid_env)
        expect(config.alerts_hashrate_min_ghs).to be_nil
      end

      it 'returns the float when parseable' do
        env = valid_env.merge('CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS' => '1234.5')
        expect(described_class.from_env(env).alerts_hashrate_min_ghs).to eq 1234.5
      end

      it 'raises ConfigError when set-but-unparseable (distinguishes from unset)' do
        env = valid_env.merge(
          'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
          'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'http://example.com/hook',
          'CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '85c'
        )
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /TEMPERATURE_MAX_C must be a valid float/)
      end

      it 'raises ConfigError when set but empty (distinguishes from unset)' do
        env = valid_env.merge(
          'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
          'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'http://example.com/hook',
          'CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => ''
        )
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /TEMPERATURE_MAX_C is set but empty/)
      end
    end

    describe 'parse_optional_int' do
      it 'returns the integer when parseable' do
        env = valid_env.merge('CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS' => '600')
        expect(described_class.from_env(env).alerts_offline_after_seconds).to eq 600
      end

      it 'raises ConfigError when set-but-unparseable' do
        env = valid_env.merge(
          'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
          'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'http://example.com/hook',
          'CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS' => '5m'
        )
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /OFFLINE_AFTER_SECONDS must be a valid integer/)
      end

      it 'raises ConfigError when set but empty' do
        env = valid_env.merge(
          'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
          'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'http://example.com/hook',
          'CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS' => ''
        )
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /OFFLINE_AFTER_SECONDS is set but empty/)
      end
    end

    describe 'validate_alerts! (only runs when alerts_enabled=true)' do
      it 'accepts a minimal valid config (one threshold, http URL, generic format)' do
        config = described_class.from_env(alerts_env)
        expect(config.alerts_enabled).to be true
        expect(config.alerts_webhook_format).to eq 'generic'
      end

      it 'raises when webhook URL is missing' do
        env = alerts_env.dup
        env.delete('CGMINER_MONITOR_ALERTS_WEBHOOK_URL')
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /alerts_webhook_url is required/)
      end

      it 'raises when webhook URL has a non-http(s) scheme' do
        env = alerts_env.merge('CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'ftp://example.com/hook')
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /scheme must be http or https/)
      end

      it 'raises when webhook URL has no host (e.g. "http:/")' do
        env = alerts_env.merge('CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'http:/')
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /must include a host/)
      end

      it 'raises on unknown webhook format' do
        env = alerts_env.merge('CGMINER_MONITOR_ALERTS_WEBHOOK_FORMAT' => 'teams')
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /alerts_webhook_format must be one of/)
      end

      it 'raises when cooldown is zero' do
        env = alerts_env.merge('CGMINER_MONITOR_ALERTS_COOLDOWN_SECONDS' => '0')
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /alerts_cooldown_seconds must be > 0/)
      end

      it 'raises when timeout is zero' do
        env = alerts_env.merge('CGMINER_MONITOR_ALERTS_WEBHOOK_TIMEOUT_SECONDS' => '0')
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /alerts_webhook_timeout_seconds must be > 0/)
      end

      it 'raises when enabled but no rule threshold configured' do
        env = alerts_env.dup
        env.delete('CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C')
        expect { described_class.from_env(env) }
          .to raise_error(CgminerMonitor::ConfigError, /no rule threshold configured/)
      end

      it 'accepts each of the three rule thresholds independently' do
        base = valid_env.merge(
          'CGMINER_MONITOR_ALERTS_ENABLED' => 'true',
          'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'http://example.com/hook'
        )
        expect do
          described_class.from_env(base.merge('CGMINER_MONITOR_ALERTS_HASHRATE_MIN_GHS' => '1000'))
        end.not_to raise_error
        expect do
          described_class.from_env(base.merge('CGMINER_MONITOR_ALERTS_TEMPERATURE_MAX_C' => '85'))
        end.not_to raise_error
        expect do
          described_class.from_env(base.merge('CGMINER_MONITOR_ALERTS_OFFLINE_AFTER_SECONDS' => '600'))
        end.not_to raise_error
      end
    end

    describe 'when alerts_enabled=false, webhook URL and thresholds are not validated' do
      it 'accepts nonsense webhook URL (disabled path)' do
        env = valid_env.merge(
          'CGMINER_MONITOR_ALERTS_WEBHOOK_URL' => 'totally bogus',
          'CGMINER_MONITOR_ALERTS_WEBHOOK_FORMAT' => 'martian'
        )
        expect { described_class.from_env(env) }.not_to raise_error
      end
    end
  end

  describe 'restart-window-suppression config' do
    it 'defaults restart_schedule_url to nil (feature disabled)' do
      config = described_class.from_env(valid_env)
      expect(config.restart_schedule_url).to be_nil
    end

    it 'defaults restart_window_grace_seconds to 300' do
      config = described_class.from_env(valid_env)
      expect(config.restart_window_grace_seconds).to eq(300)
    end

    it 'reads CGMINER_MONITOR_RESTART_SCHEDULE_URL when set' do
      env = valid_env.merge(
        'CGMINER_MONITOR_RESTART_SCHEDULE_URL' => 'http://manager.local:3000/api/v1/restart_schedules.json'
      )
      config = described_class.from_env(env)
      expect(config.restart_schedule_url).to eq('http://manager.local:3000/api/v1/restart_schedules.json')
    end

    it 'parses CGMINER_MONITOR_RESTART_WINDOW_GRACE_SECONDS as an integer' do
      env = valid_env.merge('CGMINER_MONITOR_RESTART_WINDOW_GRACE_SECONDS' => '600')
      expect(described_class.from_env(env).restart_window_grace_seconds).to eq(600)
    end

    it 'rejects a non-http(s) restart_schedule_url' do
      env = valid_env.merge('CGMINER_MONITOR_RESTART_SCHEDULE_URL' => 'ftp://manager/sched.json')
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /scheme must be http or https/)
    end

    it 'rejects a malformed restart_schedule_url' do
      env = valid_env.merge('CGMINER_MONITOR_RESTART_SCHEDULE_URL' => 'http:/')
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /must include a host/)
    end

    it 'rejects a non-positive grace' do
      env = valid_env.merge(
        'CGMINER_MONITOR_RESTART_SCHEDULE_URL' => 'http://manager/sched.json',
        'CGMINER_MONITOR_RESTART_WINDOW_GRACE_SECONDS' => '0'
      )
      expect { described_class.from_env(env) }
        .to raise_error(CgminerMonitor::ConfigError, /grace_seconds/)
    end
  end

  describe '#public_attrs' do
    it 'redacts credentials from mongo_url' do
      env = valid_env.merge('CGMINER_MONITOR_MONGO_URL' => 'mongodb://user:secret@host:27017/db')
      config = described_class.from_env(env)

      attrs = config.public_attrs
      expect(attrs[:mongo_url]).to eq 'mongodb://[REDACTED]@host:27017/db'
      expect(attrs[:interval]).to eq 30
    end

    it 'leaves non-credentialed URLs unchanged' do
      config = described_class.from_env(valid_env)
      expect(config.public_attrs[:mongo_url]).to eq 'mongodb://localhost:27017/test_db'
    end
  end

  describe '.current' do
    it 'memoizes the config' do
      env = valid_env
      allow(ENV).to receive(:fetch).and_call_original
      # .current reads from real ENV, which won't have our miners file.
      # Use from_env directly to test memoization behavior.
      described_class.instance_variable_set(:@current, described_class.from_env(env))
      expect(described_class.current).to equal(described_class.current)
    end
  end

  describe '.reset!' do
    it 'clears the memoized config' do
      described_class.instance_variable_set(:@current, :sentinel)
      described_class.reset!
      expect(described_class.instance_variable_get(:@current)).to be_nil
    end
  end
end
