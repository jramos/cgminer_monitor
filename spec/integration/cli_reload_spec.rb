# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'bin/cgminer_monitor reload', type: :integration do
  around do |example|
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
  end

  it 'exits non-zero with a helpful message when PID file is unset' do
    dir         = Dir.mktmpdir
    miners_path = File.join(dir, 'miners.yml')
    File.write(miners_path, "- host: 127.0.0.1\n  port: 4028\n")
    env = {
      'CGMINER_MONITOR_MONGO_URL' => 'mongodb://127.0.0.1:27017/test_db',
      'CGMINER_MONITOR_MINERS_FILE' => miners_path
    }
    _, err, status = Open3.capture3(env, 'bundle', 'exec', 'bin/cgminer_monitor', 'reload',
                                    chdir: File.expand_path('../..', __dir__))
    expect(status.exitstatus).not_to eq(0)
    expect(err).to match(/CGMINER_MONITOR_PID_FILE/)
  ensure
    FileUtils.rm_rf(dir)
  end
end
