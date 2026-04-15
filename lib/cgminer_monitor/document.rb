# frozen_string_literal: true

require 'cgminer_monitor/document/log'
require 'cgminer_monitor/document/devs'
require 'cgminer_monitor/document/pools'
require 'cgminer_monitor/document/stats'
require 'cgminer_monitor/document/summary'

module CgminerMonitor
  module Document
    DOCUMENT_TYPES = [Document::Devs, Document::Pools, Document::Stats, Document::Summary].freeze

    def self.document_types
      DOCUMENT_TYPES
    end

    def self.create_indexes
      document_types.each(&:create_indexes)
    end

    def self.delete_all
      document_types.each(&:delete_all)
    end
  end
end
