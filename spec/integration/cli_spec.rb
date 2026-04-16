# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe 'CLI integration', :integration do
  let(:bin_path) { File.expand_path('../../bin/cgminer_monitor', __dir__) }
  let(:env) do
    {
      'CGMINER_MONITOR_MINERS_FILE' => miners_file,
      'CGMINER_MONITOR_MONGO_URL' => ENV.fetch('CGMINER_MONITOR_MONGO_URL',
                                               'mongodb://localhost:27017/cgminer_monitor_test')
    }
  end
  let(:miners_file) do
    path = File.expand_path('../../tmp/cli_test_miners.yml', __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "- host: 10.0.0.5\n  port: 4028\n")
    path
  end

  after do
    FileUtils.rm_f(miners_file)
  end

  describe 'version' do
    it 'prints the version and exits 0' do
      stdout, stderr, status = Open3.capture3(env, "bundle exec #{bin_path} version")

      expect(status.exitstatus).to eq 0
      expect(stdout.strip).to match(/cgminer_monitor \d+\.\d+\.\d+/)
      # Ruby 3.4 emits ostruct deprecation warnings from Mongoid; filter those out
      meaningful_stderr = stderr.lines.reject { |l| l.include?('ostruct') || l.include?('warning:') }.join
      expect(meaningful_stderr).to be_empty
    end

    it 'supports -v flag' do
      stdout, _stderr, status = Open3.capture3(env, "bundle exec #{bin_path} -v")

      expect(status.exitstatus).to eq 0
      expect(stdout.strip).to match(/cgminer_monitor \d+\.\d+\.\d+/)
    end

    it 'supports --version flag' do
      stdout, _stderr, status = Open3.capture3(env, "bundle exec #{bin_path} --version")

      expect(status.exitstatus).to eq 0
      expect(stdout.strip).to match(/cgminer_monitor \d+\.\d+\.\d+/)
    end
  end

  describe 'migrate' do
    it 'creates collections and exits 0' do
      stdout, _stderr, status = Open3.capture3(env, "bundle exec #{bin_path} migrate")

      expect(status.exitstatus).to eq 0
      expect(stdout).to include('migrate: done')
    end

    it 'is idempotent — running twice succeeds' do
      Open3.capture3(env, "bundle exec #{bin_path} migrate")
      stdout, _stderr, status = Open3.capture3(env, "bundle exec #{bin_path} migrate")

      expect(status.exitstatus).to eq 0
      expect(stdout).to include('migrate: done')
    end
  end

  describe 'unknown command' do
    it 'prints an error and exits 64' do
      _stdout, stderr, status = Open3.capture3(env, "bundle exec #{bin_path} frobnicate")

      expect(status.exitstatus).to eq 64
      expect(stderr).to include("unknown command 'frobnicate'")
    end
  end

  describe 'deprecated commands' do
    it 'suggests the replacement for start' do
      _stdout, stderr, status = Open3.capture3(env, "bundle exec #{bin_path} start")

      expect(status.exitstatus).to eq 64
      expect(stderr).to include("Did you mean 'run'?")
    end

    it 'explains stop is handled by supervisor' do
      _stdout, stderr, status = Open3.capture3(env, "bundle exec #{bin_path} stop")

      expect(status.exitstatus).to eq 64
      expect(stderr).to include('Process management')
    end
  end

  describe 'no arguments' do
    it 'prints usage and exits 64' do
      _stdout, stderr, status = Open3.capture3(env, "bundle exec #{bin_path}")

      expect(status.exitstatus).to eq 64
      expect(stderr).to include('usage: cgminer_monitor')
      expect(stderr).to include('run')
      expect(stderr).to include('migrate')
      expect(stderr).to include('doctor')
      expect(stderr).to include('version')
    end
  end

  describe 'run with invalid config' do
    it 'exits non-zero when miners_file does not exist' do
      bad_env = env.merge('CGMINER_MONITOR_MINERS_FILE' => '/tmp/nonexistent_miners.yml')

      _stdout, _stderr, status = Open3.capture3(bad_env, "bundle exec #{bin_path} run")

      expect(status.exitstatus).not_to eq 0
    end
  end
end
