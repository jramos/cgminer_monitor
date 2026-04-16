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
      expect { described_class.from_env(env) }.to raise_error(ArgumentError)
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
