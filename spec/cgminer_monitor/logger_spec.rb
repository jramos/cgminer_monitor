# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerMonitor::Logger do
  let(:miner_pool) { instance_double(CgminerApiClient::MinerPool) }
  let(:logger) { described_class.new }

  before do
    allow(CgminerApiClient::MinerPool).to receive(:new).and_return(miner_pool)
  end

  describe '.log_interval' do
    it 'returns 60' do
      expect(described_class.log_interval).to eq 60
    end
  end

  describe '#miner_pool' do
    it 'creates a MinerPool on initialization' do
      expect(logger.miner_pool).to eq miner_pool
    end
  end

  describe '#log!' do
    let(:miner) do
      instance_double(CgminerApiClient::Miner, host: '10.0.0.1', port: 4028)
    end

    let(:summary_value) { [{ ghs_5s: 1234.56, ghs_av: 1230.10 }] }
    let(:success_result) { CgminerApiClient::MinerResult.success(miner, summary_value) }
    let(:error) { CgminerApiClient::ConnectionError.new('refused') }
    let(:failure_result) { CgminerApiClient::MinerResult.failure(miner, error) }

    context 'when all miners succeed' do
      let(:pool_result) { CgminerApiClient::PoolResult.new([success_result]) }

      before do
        CgminerMonitor::Document.document_types.each do |klass|
          allow(miner_pool).to receive(:query)
            .with(klass.to_s.demodulize.downcase)
            .and_return(pool_result)
        end
      end

      it 'queries the miner pool for each document type' do
        CgminerMonitor::Document.document_types.each do |klass|
          doc = klass.new
          allow(klass).to receive(:new).and_return(doc)
          allow(doc).to receive(:save!)
        end

        logger.log!

        CgminerMonitor::Document.document_types.each do |klass|
          expect(miner_pool).to have_received(:query)
            .with(klass.to_s.demodulize.downcase)
        end
      end

      it 'creates a document with unwrapped results for each type' do
        created_docs = {}

        CgminerMonitor::Document.document_types.each do |klass|
          doc = klass.new
          allow(klass).to receive(:new).and_return(doc)
          allow(doc).to receive(:save!)
          created_docs[klass] = doc
        end

        logger.log!

        created_docs.each_value do |doc|
          expect(doc.results).to eq [summary_value]
          expect(doc.created_at).to be_a Time
          expect(doc).to have_received(:save!)
        end
      end
    end

    context 'when a miner fails' do
      let(:pool_result) do
        CgminerApiClient::PoolResult.new([success_result, failure_result])
      end

      before do
        CgminerMonitor::Document.document_types.each do |klass|
          allow(miner_pool).to receive(:query)
            .with(klass.to_s.demodulize.downcase)
            .and_return(pool_result)
        end
      end

      it 'stores nil for failed miners in the results array' do
        created_docs = {}

        CgminerMonitor::Document.document_types.each do |klass|
          doc = klass.new
          allow(klass).to receive(:new).and_return(doc)
          allow(doc).to receive(:save!)
          created_docs[klass] = doc
        end

        logger.log!

        created_docs.each_value do |doc|
          expect(doc.results).to eq [summary_value, nil]
        end
      end
    end
  end
end
