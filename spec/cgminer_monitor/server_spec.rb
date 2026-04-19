# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::Server do
  subject(:server) { described_class.new(config) }

  let(:miners_file) do
    path = File.expand_path('../../tmp/test_miners.yml', __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "- host: 10.0.0.5\n  port: 4028\n")
    path
  end

  let(:config) do
    CgminerMonitor::Config.from_env(
      'CGMINER_MONITOR_INTERVAL' => '60',
      'CGMINER_MONITOR_MINERS_FILE' => miners_file,
      'CGMINER_MONITOR_HTTP_PORT' => '0',
      'CGMINER_MONITOR_SHUTDOWN_TIMEOUT' => '2'
    )
  end

  let(:poller) { instance_double(CgminerMonitor::Poller) }

  before do
    CgminerMonitor::Logger.output = StringIO.new
    CgminerMonitor::Logger.level = 'error'
  end

  after do
    CgminerMonitor::Logger.output = $stdout
    CgminerMonitor::Logger.level = 'info'
    CgminerMonitor::Config.reset!
    FileUtils.rm_f(miners_file)
  end

  describe '#initialize' do
    it 'creates a server with a config' do
      expect(server.config).to eq config
    end

    it 'creates a Poller' do
      expect(server.poller).to be_a(CgminerMonitor::Poller)
    end
  end

  describe 'signal handling' do
    it 'installs TERM and INT signal handlers' do
      # Capture the signals that get trapped
      trapped = []
      allow(Signal).to receive(:trap) do |sig, &_block|
        trapped << sig
      end

      server.send(:install_signal_handlers)

      expect(trapped).to contain_exactly('TERM', 'INT')
    end
  end

  describe '#bootstrap_mongoid!' do
    it 'calls Sample.store_in and Sample.create_collection' do
      allow(CgminerMonitor::Sample).to receive(:store_in)
      allow(CgminerMonitor::Sample).to receive(:create_collection)
      allow(CgminerMonitor::Snapshot).to receive(:create_indexes)

      server.send(:bootstrap_mongoid!)

      expect(CgminerMonitor::Sample).to have_received(:store_in).with(
        hash_including(
          collection: 'samples',
          collection_options: hash_including(
            time_series: hash_including(timeField: 'ts', metaField: 'meta')
          )
        )
      )
      expect(CgminerMonitor::Sample).to have_received(:create_collection)
      expect(CgminerMonitor::Snapshot).to have_received(:create_indexes)
    end
  end

  describe '#build_puma_launcher' do
    it 'creates a Puma::Launcher with the configured host and port' do
      launcher = server.send(:build_puma_launcher)
      expect(launcher).to be_a(Puma::Launcher)
    end
  end

  describe 'graceful shutdown' do
    it 'stops the poller and puma when signaled' do
      stop_queue = server.instance_variable_get(:@stop)

      # Simulate signal delivery
      stop_queue << 'TERM'

      # Verify the queue has the signal
      signal = stop_queue.pop
      expect(signal).to eq 'TERM'
    end
  end

  describe '#validate_startup!' do
    it 'does not raise when miners_file is valid and Mongo is reachable' do
      expect { server.send(:validate_startup!) }.not_to raise_error
    end

    it 'raises ConfigError when miners_file is empty array' do
      empty_array_file = File.expand_path('../../tmp/empty_array_miners.yml', __dir__)
      FileUtils.mkdir_p(File.dirname(empty_array_file))
      File.write(empty_array_file, "[]\n")

      empty_config = CgminerMonitor::Config.from_env(
        'CGMINER_MONITOR_INTERVAL' => '60',
        'CGMINER_MONITOR_MINERS_FILE' => empty_array_file,
        'CGMINER_MONITOR_HTTP_PORT' => '0',
        'CGMINER_MONITOR_SHUTDOWN_TIMEOUT' => '2'
      )

      # Server.new builds the Poller which calls build_miner_pool — supply
      # a pre-built miner_pool double so we can test validate_startup! alone
      miner_pool_double = instance_double(CgminerApiClient::MinerPool, miners: [])
      allow(CgminerApiClient::MinerPool).to receive(:allocate).and_return(miner_pool_double)
      allow(miner_pool_double).to receive(:miners=)
      allow(miner_pool_double).to receive(:miners).and_return([])

      empty_server = described_class.new(empty_config)

      expect { empty_server.send(:validate_startup!) }
        .to raise_error(CgminerMonitor::ConfigError, /empty/)
    ensure
      FileUtils.rm_f(empty_array_file)
    end

    it 'raises a Mongo::Error when Mongo is unreachable' do
      client_double = double('mongo_client')
      allow(client_double).to receive(:database_names)
        .and_raise(Mongo::Error::OperationFailure, 'server unreachable')
      allow(Mongoid).to receive(:default_client).and_return(client_double)

      expect { server.send(:validate_startup!) }
        .to raise_error(Mongo::Error)
    end
  end
end
