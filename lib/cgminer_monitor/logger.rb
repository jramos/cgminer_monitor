module CgminerMonitor
  class Logger
    attr_accessor :miner_pool

    def initialize
      @miner_pool = CgminerApiClient::MinerPool.new
    end
  end
end