# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::Poller do
  subject(:poller) { described_class.new(config, miner_pool: miner_pool) }

  let(:miner) do
    instance_double(CgminerApiClient::Miner, host: '10.0.0.5', port: 4028)
  end

  let(:miner_pool) { instance_double(CgminerApiClient::MinerPool, miners: [miner]) }

  let(:summary_response) do
    [{ 'SUMMARY' => [{ 'Elapsed' => 12_345,
                       'GHS 5s' => 1234.56,
                       'GHS av' => 1230.10,
                       'Hardware Errors' => 3,
                       'Utility' => 0.42,
                       'Device Hardware%' => 0.001,
                       'Device Rejected%' => 0.0,
                       'Pool Rejected%' => 0.0,
                       'Pool Stale%' => 0.0,
                       'Best Share' => 999_999 }],
       'STATUS' => [{ 'STATUS' => 'S', 'Msg' => 'Summary' }] }]
  end

  let(:devs_response) do
    [{ 'DEVS' => [
         { 'ASC' => 0, 'Temperature' => 60.5, 'Status' => 'Alive',
           'MHS 5s' => 4321.0, 'Accepted' => 100, 'Rejected' => 2 },
         { 'ASC' => 1, 'Temperature' => 65.0, 'Status' => 'Alive',
           'MHS 5s' => 4320.0, 'Accepted' => 99, 'Rejected' => 1 }
       ],
       'STATUS' => [{ 'STATUS' => 'S', 'Msg' => 'Devs' }] }]
  end

  let(:pools_response) do
    [{ 'POOLS' => [{ 'URL' => 'stratum+tcp://pool.example:3333',
                     'User' => 'worker1',
                     'Accepted' => 500,
                     'Rejected' => 5,
                     'Stale' => 1,
                     'Priority' => 0,
                     'Quota' => 1 }],
       'STATUS' => [{ 'STATUS' => 'S', 'Msg' => 'Pools' }] }]
  end

  let(:stats_response) do
    [{ 'STATS' => [{ 'ID' => 'AntS9',
                     'Elapsed' => 12_345,
                     'temp1' => 60,
                     'temp2' => 65,
                     'temp3' => 63,
                     'chain_acs1' => 'oooooooo' }],
       'STATUS' => [{ 'STATUS' => 'S', 'Msg' => 'Stats' }] }]
  end

  let(:success_result) do
    ->(response) { CgminerApiClient::MinerResult.success(miner, response) }
  end

  let(:miners_file_path) do
    path = File.expand_path('../../tmp/test_miners.yml', __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "- host: 10.0.0.5\n  port: 4028\n")
    path
  end

  let(:config) do
    CgminerMonitor::Config.from_env(
      'CGMINER_MONITOR_INTERVAL' => '60',
      'CGMINER_MONITOR_MINERS_FILE' => miners_file_path
    )
  end

  before do
    CgminerMonitor::Logger.output = StringIO.new
    CgminerMonitor::Logger.level = 'error'

    allow(miner_pool).to receive(:query).with('summary')
                                        .and_return(CgminerApiClient::PoolResult.new([success_result.call(summary_response)]))
    allow(miner_pool).to receive(:query).with('devs')
                                        .and_return(CgminerApiClient::PoolResult.new([success_result.call(devs_response)]))
    allow(miner_pool).to receive(:query).with('pools')
                                        .and_return(CgminerApiClient::PoolResult.new([success_result.call(pools_response)]))
    allow(miner_pool).to receive(:query).with('stats')
                                        .and_return(CgminerApiClient::PoolResult.new([success_result.call(stats_response)]))
  end

  after do
    CgminerMonitor::Logger.output = $stdout
    CgminerMonitor::Logger.level = 'info'
    FileUtils.rm_f(miners_file_path)
  end

  describe '#poll_once' do
    it 'queries all four cgminer commands' do
      poller.poll_once

      %w[summary devs pools stats].each do |cmd|
        expect(miner_pool).to have_received(:query).with(cmd)
      end
    end

    it 'writes numeric samples for summary fields' do
      poller.poll_once

      samples = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'summary'
      )

      metrics = samples.map { |s| s.meta['metric'] }
      expect(metrics).to include('ghs_5s', 'ghs_av', 'elapsed', 'hardware_errors',
                                 'utility', 'device_hardware%', 'device_rejected%',
                                 'pool_rejected%', 'pool_stale%', 'best_share')

      ghs_5s = samples.find { |s| s.meta['metric'] == 'ghs_5s' }
      expect(ghs_5s.v).to eq 1234.56
    end

    it 'writes numeric samples for devs fields with correct sub index' do
      poller.poll_once

      dev0_temp = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'devs',
        'meta.sub' => 0,
        'meta.metric' => 'temperature'
      ).first

      expect(dev0_temp).not_to be_nil
      expect(dev0_temp.v).to eq 60.5

      dev1_temp = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'devs',
        'meta.sub' => 1,
        'meta.metric' => 'temperature'
      ).first

      expect(dev1_temp).not_to be_nil
      expect(dev1_temp.v).to eq 65.0
    end

    it 'ignores non-numeric fields (strings, booleans, arrays, hashes)' do
      poller.poll_once

      status_samples = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'devs',
        'meta.metric' => 'status'
      )
      expect(status_samples.count).to eq 0

      # chain_acs1 is a string — should not appear as a sample
      chain_samples = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'stats',
        'meta.metric' => 'chain_acs1'
      )
      expect(chain_samples.count).to eq 0
    end

    it 'writes stats temp fields as samples' do
      poller.poll_once

      temp_samples = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'stats',
        'meta.metric' => /^temp/
      )

      expect(temp_samples.count).to eq 3
      expect(temp_samples.map(&:v)).to contain_exactly(60.0, 65.0, 63.0)
    end

    it 'upserts snapshots for all four commands' do
      poller.poll_once

      %w[summary devs pools stats].each do |cmd|
        snapshot = CgminerMonitor::Snapshot.where(
          miner: '10.0.0.5:4028',
          command: cmd
        ).first

        expect(snapshot).not_to be_nil
        expect(snapshot.ok).to be true
        expect(snapshot.response).not_to be_nil
        expect(snapshot.error).to be_nil
      end
    end

    it 'writes synthetic poll/ok=1 sample on success' do
      poller.poll_once

      poll_ok = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'poll',
        'meta.metric' => 'ok'
      ).first

      expect(poll_ok).not_to be_nil
      expect(poll_ok.v).to eq 1.0
    end

    it 'writes synthetic poll/duration_ms sample' do
      poller.poll_once

      duration = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'poll',
        'meta.metric' => 'duration_ms'
      ).first

      expect(duration).not_to be_nil
      expect(duration.v).to be >= 0
    end

    it 'increments polls_ok counter on success' do
      poller.poll_once
      expect(poller.polls_ok).to eq 1

      poller.poll_once
      expect(poller.polls_ok).to eq 2
    end
  end

  describe 'failed miner poll' do
    let(:error) { CgminerApiClient::ConnectionError.new('refused') }
    let(:failure_result) { CgminerApiClient::MinerResult.failure(miner, error) }

    before do
      %w[summary devs pools stats].each do |cmd|
        allow(miner_pool).to receive(:query).with(cmd)
                                            .and_return(CgminerApiClient::PoolResult.new([failure_result]))
      end
    end

    it 'writes snapshot with ok=false and error message' do
      poller.poll_once

      snapshot = CgminerMonitor::Snapshot.where(
        miner: '10.0.0.5:4028',
        command: 'summary'
      ).first

      expect(snapshot.ok).to be false
      expect(snapshot.error).to include('ConnectionError')
      expect(snapshot.error).to include('refused')
    end

    it 'writes synthetic poll/ok=0 sample on failure' do
      poller.poll_once

      poll_ok = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'poll',
        'meta.metric' => 'ok'
      ).first

      expect(poll_ok).not_to be_nil
      expect(poll_ok.v).to eq 0.0
    end

    it 'increments polls_failed counter' do
      poller.poll_once
      expect(poller.polls_failed).to eq 1
    end

    it 'does not raise — the loop continues' do
      expect { poller.poll_once }.not_to raise_error
    end
  end

  describe '#stop' do
    it 'sets the stopped flag' do
      expect(poller).not_to be_stopped
      poller.stop
      expect(poller).to be_stopped
    end
  end

  describe 'metric extraction edge cases' do
    let(:numeric_string_response) do
      [{ 'SUMMARY' => [{ 'Elapsed' => '12345', 'GHS 5s' => '1234.56' }],
         'STATUS' => [{ 'STATUS' => 'S' }] }]
    end

    it 'parses numeric string values as floats' do
      allow(miner_pool).to receive(:query).with('summary')
                                          .and_return(CgminerApiClient::PoolResult.new([success_result.call(numeric_string_response)]))

      poller.poll_once

      elapsed = CgminerMonitor::Sample.where(
        'meta.miner' => '10.0.0.5:4028',
        'meta.command' => 'summary',
        'meta.metric' => 'elapsed'
      ).first

      expect(elapsed.v).to eq 12_345.0
    end
  end
end
