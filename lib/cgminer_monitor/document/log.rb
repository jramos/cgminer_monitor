module CgminerMonitor
  module Document
    class Log
      include Mongoid::Document

      index({ created_at: 1 })

      def self.last_entry
        self.last_entries(1)
      end

      def self.last_entries(n)
        order_by(:created_at.desc).limit(n)
      end
    end
  end
end