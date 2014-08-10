module CgminerMonitor
  class Logger
    attr_accessor :miner_pool

    def initialize
      @miner_pool = CgminerApiClient::MinerPool.new
    end

    def log!
      created_at = Time.now

      CgminerMonitor::Document.document_types.each do |klass|
        if query_results = @miner_pool.query(klass.to_s.demodulize.downcase)
          doc = klass.new
          doc.update_attribute(:results, query_results)
          doc.update_attribute(:created_at, created_at)
          doc.save!
        end
      end
    end
  end
end