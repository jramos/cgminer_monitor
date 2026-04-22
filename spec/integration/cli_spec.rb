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

  # SIGHUP path: spawn a real cgminer_monitor, rewrite miners.yml,
  # send SIGHUP, and assert reload.signal_received + reload.ok appear in
  # captured stdout. The log-match is the regression guard against a
  # future change that silently swallows SIGHUP — e.g., Puma reinstalling
  # its own HUP trap (which calls stop()) between our install and the
  # process boundary. Relies on Mongo at localhost:27017; skipped when
  # Mongo isn't reachable.
  describe 'reload via SIGHUP', :integration do
    def wait_for_bind!(host, port, timeout: 15)
      deadline = Time.now + timeout
      until Time.now >= deadline
        begin
          TCPSocket.new(host, port).close
          return
        rescue Errno::ECONNREFUSED, Errno::EINVAL
          Thread.pass
        end
      end
      raise 'server did not bind within deadline'
    end

    it 'reloads miners on SIGHUP' do
      dir = Dir.mktmpdir
      sighup_miners = File.join(dir, 'miners.yml')
      pid_path      = File.join(dir, 'cm-monitor.pid')
      File.write(sighup_miners, "- host: 127.0.0.1\n  port: 4028\n")

      port = 9293 # fixed port; avoids TIME_WAIT races from ephemeral port reuse

      spawn_env = {
        'CGMINER_MONITOR_MINERS_FILE' => sighup_miners,
        'CGMINER_MONITOR_MONGO_URL' => env['CGMINER_MONITOR_MONGO_URL'],
        'CGMINER_MONITOR_HTTP_PORT' => port.to_s,
        'CGMINER_MONITOR_HTTP_HOST' => '127.0.0.1',
        'CGMINER_MONITOR_SHUTDOWN_TIMEOUT' => '3',
        'CGMINER_MONITOR_PID_FILE' => pid_path,
        'CGMINER_MONITOR_LOG_FORMAT' => 'json'
      }

      log_r, log_w = IO.pipe
      pid = spawn(spawn_env, 'bundle', 'exec', bin_path, 'run',
                  out: log_w, err: log_w)
      log_w.close

      captured = +''
      begin
        wait_for_bind!('127.0.0.1', port)

        deadline = Time.now + 5
        sleep 0.05 until File.exist?(pid_path) || Time.now > deadline
        expect(File.read(pid_path).strip).to eq(pid.to_s)

        File.write(sighup_miners,
                   "- host: 127.0.0.1\n  port: 4028\n" \
                   "- host: 127.0.0.1\n  port: 4029\n")
        Process.kill('HUP', pid)

        # Poll the log pipe for reload.ok with a deadline instead of
        # sleep(0.5). The stdout fd is non-blocking-read via select;
        # this eliminates the "under CI load the dispatcher hasn't
        # processed the signal yet" flake and races.
        deadline = Time.now + 5
        until Time.now > deadline
          captured << log_r.read_nonblock(65_536) if log_r.wait_readable(0.1)
          break if captured.include?('reload.ok')
        end
        expect(captured).to include('reload.signal_received')
        expect(captured).to include('reload.ok')
      ensure
        Process.kill('TERM', pid) rescue nil # rubocop:disable Style/RescueModifier
        Process.wait(pid)
        # Drain any trailing output the server emitted during shutdown.
        begin
          captured << log_r.read
        rescue IOError
          # pipe already closed — fine
        end
        log_r.close
        FileUtils.rm_rf(dir)
      end
    end
  end
end
