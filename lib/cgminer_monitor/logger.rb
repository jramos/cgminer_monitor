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
      documents = []

      CgminerMonitor::Document.document_types.each do |klass|
        if query_results = @miner_pool.query(klass.to_s.demodulize.downcase)
          doc = klass.new
          doc.update_attribute(:results, query_results)
          doc.update_attribute(:created_at, created_at)
          doc.save!
          documents << doc
        end
      end

      documents
    end
  end
end