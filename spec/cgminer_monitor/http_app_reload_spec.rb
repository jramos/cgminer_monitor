# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe CgminerMonitor::HttpApp, '.reload_miners!' do # rubocop:disable RSpec/SpecFilePathFormat
  let(:dir)  { Dir.mktmpdir }
  let(:path) { File.join(dir, 'miners.yml') }

  before do
    File.write(path, "- host: 10.0.0.1\n  port: 4028\n")
    described_class.configure_for_test!(
      miners: described_class.parse_miners_file(path)
    )
  end

  after do
    described_class.configure_for_test!(miners: nil, poller: nil, started_at: nil)
    FileUtils.rm_rf(dir)
  end

  it 'swaps configured_miners with the freshly parsed file' do
    File.write(path, "- host: 10.0.0.2\n  port: 4028\n")
    expect(described_class.reload_miners!(path)).to eq(1)
    expect(described_class.settings.configured_miners)
      .to eq([['10.0.0.2:4028', '10.0.0.2', 4028]])
  end

  it 'keeps old miners and returns nil when YAML is malformed' do
    old = described_class.settings.configured_miners
    File.write(path, 'not: [valid')
    expect(described_class.reload_miners!(path)).to be_nil
    expect(described_class.settings.configured_miners).to equal(old)
  end

  it 'keeps old miners when file goes missing' do
    old = described_class.settings.configured_miners
    File.unlink(path)
    expect(described_class.reload_miners!(path)).to be_nil
    expect(described_class.settings.configured_miners).to equal(old)
  end

  it 'keeps old miners when the top-level YAML is not a list' do
    old = described_class.settings.configured_miners
    File.write(path, "just-a-scalar\n")
    expect(described_class.reload_miners!(path)).to be_nil
    expect(described_class.settings.configured_miners).to equal(old)
  end
end
