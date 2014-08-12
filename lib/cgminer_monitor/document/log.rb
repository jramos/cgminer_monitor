module CgminerMonitor
  module Document
    class Log
      include Mongoid::Document

      index({ created_at: 1 }, { unique: true })
      index({ results: 1 })
    end
  end
end