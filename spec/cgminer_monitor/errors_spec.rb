# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'CgminerMonitor error hierarchy' do
  it 'defines Error as a subclass of StandardError' do
    expect(CgminerMonitor::Error).to be < StandardError
  end

  it 'defines ConfigError as a subclass of Error' do
    expect(CgminerMonitor::ConfigError).to be < CgminerMonitor::Error
  end

  it 'defines StorageError as a subclass of Error' do
    expect(CgminerMonitor::StorageError).to be < CgminerMonitor::Error
  end

  it 'defines PollError as a subclass of Error' do
    expect(CgminerMonitor::PollError).to be < CgminerMonitor::Error
  end

  it 'can be rescued as StandardError' do
    expect { raise CgminerMonitor::ConfigError, 'bad config' }
      .to raise_error(StandardError, 'bad config')
  end
end
