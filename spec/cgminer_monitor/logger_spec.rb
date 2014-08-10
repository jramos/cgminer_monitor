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

  context '.initialize' do
    it 'should create a new miner_pool' do
      expect(CgminerApiClient::MinerPool).to receive(:new).and_return(:foo)
      expect(instance.instance_variable_get(:@miner_pool)).to eq :foo
    end
  end
end