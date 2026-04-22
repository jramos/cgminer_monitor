# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::Server do
  describe '#install_signal_handlers' do
    it 'traps INT and TERM as :stop and HUP as :reload into @signals' do
      server = described_class.allocate
      server.instance_variable_set(:@config, instance_double(CgminerMonitor::Config))
      server.instance_variable_set(:@signals, Queue.new)

      trapped = {}
      allow(Signal).to receive(:trap) do |sig, &blk|
        trapped[sig] = blk
      end

      server.send(:install_signal_handlers)

      %w[INT TERM HUP].each { |s| expect(trapped).to have_key(s) }

      trapped['INT'].call
      trapped['TERM'].call
      trapped['HUP'].call

      signals = server.instance_variable_get(:@signals)
      drained = [signals.pop, signals.pop, signals.pop]
      expect(drained).to contain_exactly(:stop, :stop, :reload)
    end
  end

  describe '#perform_reload' do
    it 'reloads poller + HttpApp and logs reload.ok only when both succeed' do
      poller = instance_double(CgminerMonitor::Poller, reload!: 3)
      config = instance_double(CgminerMonitor::Config, miners_file: '/tmp/m.yml')
      server = described_class.allocate
      server.instance_variable_set(:@poller, poller)
      server.instance_variable_set(:@config, config)

      allow(CgminerMonitor::HttpApp).to receive(:reload_miners!).with('/tmp/m.yml').and_return(3)
      allow(CgminerMonitor::Logger).to receive(:info)

      server.send(:perform_reload)

      expect(CgminerMonitor::Logger).to have_received(:info).with(event: 'reload.signal_received')
      expect(CgminerMonitor::Logger).to have_received(:info).with(event: 'reload.ok', miners: 3)
    end

    it 'does not log reload.ok when poller reload fails' do
      poller = instance_double(CgminerMonitor::Poller, reload!: nil)
      config = instance_double(CgminerMonitor::Config, miners_file: '/tmp/m.yml')
      server = described_class.allocate
      server.instance_variable_set(:@poller, poller)
      server.instance_variable_set(:@config, config)

      allow(CgminerMonitor::HttpApp).to receive(:reload_miners!).and_return(3)
      allow(CgminerMonitor::Logger).to receive(:info)

      server.send(:perform_reload)

      expect(CgminerMonitor::Logger).not_to have_received(:info).with(hash_including(event: 'reload.ok'))
    end

    it 'does not log reload.ok when HttpApp reload fails' do
      poller = instance_double(CgminerMonitor::Poller, reload!: 3)
      config = instance_double(CgminerMonitor::Config, miners_file: '/tmp/m.yml')
      server = described_class.allocate
      server.instance_variable_set(:@poller, poller)
      server.instance_variable_set(:@config, config)

      allow(CgminerMonitor::HttpApp).to receive(:reload_miners!).and_return(nil)
      allow(CgminerMonitor::Logger).to receive(:info)

      server.send(:perform_reload)

      expect(CgminerMonitor::Logger).not_to have_received(:info).with(hash_including(event: 'reload.ok'))
    end

    it 'logs reload.partial when poller succeeds but HttpApp fails' do
      poller = instance_double(CgminerMonitor::Poller, reload!: 3)
      config = instance_double(CgminerMonitor::Config, miners_file: '/tmp/m.yml')
      server = described_class.allocate
      server.instance_variable_set(:@poller, poller)
      server.instance_variable_set(:@config, config)

      allow(CgminerMonitor::HttpApp).to receive(:reload_miners!).and_return(nil)
      allow(CgminerMonitor::Logger).to receive(:info)
      allow(CgminerMonitor::Logger).to receive(:error)

      server.send(:perform_reload)

      expect(CgminerMonitor::Logger).to have_received(:error)
        .with(event: 'reload.partial', poller_ok: true, http_app_ok: false)
    end

    it 'logs reload.partial when HttpApp succeeds but poller fails' do
      poller = instance_double(CgminerMonitor::Poller, reload!: nil)
      config = instance_double(CgminerMonitor::Config, miners_file: '/tmp/m.yml')
      server = described_class.allocate
      server.instance_variable_set(:@poller, poller)
      server.instance_variable_set(:@config, config)

      allow(CgminerMonitor::HttpApp).to receive(:reload_miners!).and_return(3)
      allow(CgminerMonitor::Logger).to receive(:info)
      allow(CgminerMonitor::Logger).to receive(:error)

      server.send(:perform_reload)

      expect(CgminerMonitor::Logger).to have_received(:error)
        .with(event: 'reload.partial', poller_ok: false, http_app_ok: true)
    end

    it 'does not log reload.partial when both sides fail' do
      poller = instance_double(CgminerMonitor::Poller, reload!: nil)
      config = instance_double(CgminerMonitor::Config, miners_file: '/tmp/m.yml')
      server = described_class.allocate
      server.instance_variable_set(:@poller, poller)
      server.instance_variable_set(:@config, config)

      allow(CgminerMonitor::HttpApp).to receive(:reload_miners!).and_return(nil)
      allow(CgminerMonitor::Logger).to receive(:info)
      allow(CgminerMonitor::Logger).to receive(:error)

      server.send(:perform_reload)

      expect(CgminerMonitor::Logger).not_to have_received(:error).with(hash_including(event: 'reload.partial'))
    end
  end

  describe '#write_pid_file / #unlink_pid_file' do
    let(:pid_path) { File.join(Dir.mktmpdir, 'test.pid') }
    let(:config)   { instance_double(CgminerMonitor::Config, pid_file: pid_path) }
    let(:server) do
      s = described_class.allocate
      s.instance_variable_set(:@config, config)
      s
    end

    after { FileUtils.rm_f(pid_path) }

    it 'writes the current pid to the configured path' do
      allow(CgminerMonitor::Logger).to receive(:info)
      server.send(:write_pid_file)
      expect(File.read(pid_path).strip).to eq(Process.pid.to_s)
    end

    it 'unlinks the pid file' do
      File.write(pid_path, "#{Process.pid}\n")
      server.send(:unlink_pid_file)
      expect(File.exist?(pid_path)).to be(false)
    end

    it 'tolerates an already-deleted pid file on unlink' do
      expect { server.send(:unlink_pid_file) }.not_to raise_error
    end

    it 'is a no-op when pid_file is nil' do
      allow(config).to receive(:pid_file).and_return(nil)
      expect { server.send(:write_pid_file) }.not_to raise_error
      expect { server.send(:unlink_pid_file) }.not_to raise_error
    end
  end
end
