module CgminerMonitor
  module Document
    class Pools
      include Mongoid::Document

      index({ created_at: 1 }, { unique: true })
    end
  end
end