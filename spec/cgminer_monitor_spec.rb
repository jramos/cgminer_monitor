# frozen_string_literal: true

require 'spec_helper'

describe CgminerMonitor do
  subject { CgminerMonitor }

  it 'has a version constant' do
    expect(subject::VERSION).to be_a(String)
  end
end
