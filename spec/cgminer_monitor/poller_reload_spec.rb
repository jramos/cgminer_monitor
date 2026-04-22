# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe CgminerMonitor::Poller, '#reload!' do
  let(:dir)  { Dir.mktmpdir }
  let(:path) { File.join(dir, 'miners.yml') }
  let(:config) do
    instance_double(CgminerMonitor::Config,
                    miners_file: path,
                    interval: 60,
                    shutdown_timeout: 5)
  end

  before { File.write(path, "- host: 10.0.0.1\n  port: 4028\n") }
  after  { FileUtils.rm_rf(dir) }

  it 'rebuilds @miner_pool from the updated file' do
    poller = described_class.new(config)
    expect(poller.instance_variable_get(:@miner_pool).miners.map(&:host))
      .to eq(['10.0.0.1'])

    File.write(path, "- host: 10.0.0.2\n  port: 4028\n")
    expect(poller.reload!).to eq(1)
    expect(poller.instance_variable_get(:@miner_pool).miners.map(&:host))
      .to eq(['10.0.0.2'])
  end

  it 'keeps the old pool on bad YAML' do
    poller = described_class.new(config)
    old = poller.instance_variable_get(:@miner_pool)
    File.write(path, 'not: [valid')
    expect(poller.reload!).to be_nil
    expect(poller.instance_variable_get(:@miner_pool)).to equal(old)
  end

  it 'keeps the old pool when file is missing' do
    poller = described_class.new(config)
    old = poller.instance_variable_get(:@miner_pool)
    File.unlink(path)
    expect(poller.reload!).to be_nil
    expect(poller.instance_variable_get(:@miner_pool)).to equal(old)
  end

  # Core correctness invariant for the poll_once pool-capture refactor:
  # a reload! that lands mid-tick must not divert subsequent pool.query
  # calls in the same poll_once to the freshly-swapped pool. The
  # capture at poll_once:26 and the threaded `pool` parameter down into
  # poll_miner is what upholds this; a regression that re-reads
  # @miner_pool inside poll_miner would silently break it and none of
  # the other tests would notice.
  it 'keeps querying the captured pool after a mid-tick reload!' do
    poller = described_class.new(config)
    original_pool = poller.instance_variable_get(:@miner_pool)
    miner = original_pool.miners.first

    # Replace build_miner_pool so reload! swaps in a distinct double.
    new_pool = instance_double(CgminerApiClient::MinerPool, miners: [miner])
    allow(poller).to receive(:build_miner_pool).and_return(new_pool)

    miner_id = "#{miner.host}:#{miner.port}"
    per_miner_result = instance_double(CgminerApiClient::MinerResult, ok?: false, error: StandardError.new('stub'))

    # Original pool's first query call triggers the swap. All four
    # subsequent pool.query calls in this tick must still hit
    # `original_pool`, not `new_pool`.
    call_count = 0
    allow(original_pool).to receive(:query) do
      call_count += 1
      poller.reload! if call_count == 1 # swap happens after first query
      { miner_id => per_miner_result }
    end
    allow(new_pool).to receive(:query).and_raise('new pool must not be queried in the same tick')

    allow(poller).to receive(:write_snapshots)
    allow(CgminerMonitor::Logger).to receive(:warn)
    allow(CgminerMonitor::Logger).to receive(:info)

    expect { poller.poll_once }.not_to raise_error

    expect(call_count).to eq(CgminerMonitor::Poller::COMMANDS.size)
    expect(new_pool).not_to have_received(:query)
    # Sanity: reload! did land, ivar is now the new pool for the *next* tick.
    expect(poller.instance_variable_get(:@miner_pool)).to equal(new_pool)
  end
end
