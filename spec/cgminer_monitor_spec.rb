# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor do
  it 'has a version constant' do
    expect(described_class::VERSION).not_to be_nil
  end

  it 'has a .version method' do
    expect(described_class.version).to eq described_class::VERSION
  end
end
