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
end
