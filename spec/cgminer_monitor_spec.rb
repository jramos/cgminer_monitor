require 'spec_helper'

describe CgminerMonitor do
  subject  { CgminerMonitor }

  it 'should have a version constant' do
    subject::VERSION
  end
end