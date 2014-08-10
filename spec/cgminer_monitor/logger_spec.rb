require 'spec_helper'

describe CgminerMonitor::Logger do
  let(:instance) { CgminerMonitor::Logger.new }

  context 'attributes' do
    context '@miner_pool' do
      it 'should allow setting and getting' do
        instance.miner_pool = :foo
        expect(instance.miner_pool).to eq :foo
      end
    end
  end

  context '#initialize' do
    it 'should create a new miner_pool' do
      expect(CgminerApiClient::MinerPool).to receive(:new).and_return(:foo)
      expect(instance.instance_variable_get(:@miner_pool)).to eq :foo
    end
  end

  context '#log!' do
    let(:miner_pool) { instance_double(CgminerApiClient::MinerPool) }

    before do
      instance.instance_variable_set(:@miner_pool, miner_pool)
    end

    it 'should query the mining pool for all document_types' do
      CgminerMonitor::Document.document_types.each do |klass|
        expect(miner_pool).to receive(:query).with(klass.to_s.demodulize.downcase).and_return(:results)
      end

      instance.log!
    end

    it 'should create new documents'
  end
end