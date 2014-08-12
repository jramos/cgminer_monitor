module CgminerMonitor
  module Document
    class Log
      include Mongoid::Document

      index({ created_at: 1 })
      index({ results: 1 })

      def self.last_entry
        order_by(:created_at.desc).first
      end
    end
  end
end