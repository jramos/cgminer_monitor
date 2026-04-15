# frozen_string_literal: true

require 'spec_helper'

describe CgminerMonitor::Logger do
  let(:instance) { CgminerMonitor::Logger.new }

  context 'attributes' do
    context '@miner_pool' do
      it 'allows setting and getting' do
        instance.miner_pool = :foo
        expect(instance.miner_pool).to eq :foo
      end
    end
  end

  describe '#initialize' do
    it 'creates a new miner_pool' do
      expect(CgminerApiClient::MinerPool).to receive(:new).and_return(:foo)
      expect(instance.instance_variable_get(:@miner_pool)).to eq :foo
    end
  end

  describe '#log!' do
    let(:miner_pool) { instance_double(CgminerApiClient::MinerPool) }

    before do
      instance.instance_variable_set(:@miner_pool, miner_pool)
    end

    it 'queries the mining pool for all document_types' do
      CgminerMonitor::Document.document_types.each do |klass|
        expect(miner_pool).to receive(:query).with(klass.to_s.demodulize.downcase)
      end

      instance.log!
    end

    it 'should create new documents'
  end
end
