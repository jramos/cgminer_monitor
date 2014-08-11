module CgminerMonitor
  module Document
    class Stats
      include Mongoid::Document

      index({ created_at: 1 }, { unique: true })
    end
  end
end