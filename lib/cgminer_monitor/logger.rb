# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'

module CgminerMonitor
  class Logger
    attr_accessor :miner_pool

    LOG_INTERVAL = 60

    def initialize
      @miner_pool = CgminerApiClient::MinerPool.new
    end

    def self.log_interval
      LOG_INTERVAL
    end

    def log!
      created_at = Time.now

      CgminerMonitor::Document.document_types.each do |klass|
        pool_result = @miner_pool.query(klass.to_s.demodulize.downcase)
        results = pool_result.map { |mr| mr.ok? ? mr.value : nil }

        doc = klass.new
        doc.results = results
        doc.created_at = created_at
        doc.save!
      end
    end
  end
end
