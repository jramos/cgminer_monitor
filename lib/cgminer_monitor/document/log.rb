# frozen_string_literal: true

module CgminerMonitor
  module Document
    class Log
      include Mongoid::Document

      field :results,    type: Array
      field :created_at, type: Time

      def results=(value)
        attributes['results'] = value
      end

      index({ created_at: 1 })

      def self.last_entry
        last_entries(1).first
      end

      def self.last_entries(num)
        order_by(created_at: :desc).limit(num)
      end
    end
  end
end
