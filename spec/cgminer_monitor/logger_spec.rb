# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe CgminerMonitor::Logger do
  let(:output) { StringIO.new }

  before do
    described_class.output = output
    described_class.format = 'json'
    described_class.level = 'debug'
  end

  after do
    described_class.output = $stdout
    described_class.format = 'json'
    described_class.level = 'info'
  end

  describe '.info' do
    it 'writes a JSON line with level info' do
      described_class.info(event: 'test.event', key: 'value')

      line = JSON.parse(output.string.chomp)
      expect(line['level']).to eq 'info'
      expect(line['event']).to eq 'test.event'
      expect(line['key']).to eq 'value'
      expect(line['ts']).not_to be_nil
    end
  end

  describe '.warn' do
    it 'writes a JSON line with level warn' do
      described_class.warn(event: 'warning.event')

      line = JSON.parse(output.string.chomp)
      expect(line['level']).to eq 'warn'
      expect(line['event']).to eq 'warning.event'
    end
  end

  describe '.error' do
    it 'writes a JSON line with level error' do
      described_class.error(event: 'error.event', message: 'something broke')

      line = JSON.parse(output.string.chomp)
      expect(line['level']).to eq 'error'
      expect(line['message']).to eq 'something broke'
    end
  end

  describe '.debug' do
    it 'writes a JSON line with level debug' do
      described_class.debug(event: 'debug.event')

      line = JSON.parse(output.string.chomp)
      expect(line['level']).to eq 'debug'
    end

    it 'is suppressed when log level is info' do
      described_class.level = 'info'
      described_class.debug(event: 'debug.event')

      expect(output.string).to be_empty
    end
  end

  describe 'level filtering' do
    it 'suppresses info when level is warn' do
      described_class.level = 'warn'
      described_class.info(event: 'should.not.appear')
      expect(output.string).to be_empty
    end

    it 'allows error when level is warn' do
      described_class.level = 'warn'
      described_class.error(event: 'should.appear')
      expect(output.string).not_to be_empty
    end
  end

  describe 'text format' do
    it 'writes a human-readable line instead of JSON' do
      described_class.format = 'text'
      described_class.info(event: 'server.start', pid: 1234)

      line = output.string.chomp
      expect(line).to include('INFO')
      expect(line).to include('server.start')
      expect(line).to include('pid=1234')
    end
  end

  describe 'thread safety' do
    it 'does not interleave output from concurrent writes' do
      threads = 10.times.map do |i|
        Thread.new { described_class.info(event: 'concurrent', i: i) }
      end
      threads.each(&:join)

      lines = output.string.split("\n")
      expect(lines.size).to eq 10
      lines.each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end
  end
end
