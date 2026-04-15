# frozen_string_literal: true

module CgminerMonitor
  module Document
    class Log
      include Mongoid::Document

      index({ created_at: 1 })

      def self.last_entry
        last_entries(1).first
      end

      def self.last_entries(num)
        order_by(:created_at.desc).limit(num)
      end
    end
  end
end
