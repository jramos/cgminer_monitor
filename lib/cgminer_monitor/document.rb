require 'cgminer_monitor/document/log'
require 'cgminer_monitor/document/devs'
require 'cgminer_monitor/document/pools'
require 'cgminer_monitor/document/stats'
require 'cgminer_monitor/document/summary'

module CgminerMonitor
  module Document
    DOCUMENT_TYPES = [Document::Devs, Document::Pools, Document::Stats, Document::Summary]

    def self.document_types
      DOCUMENT_TYPES
    end
  end
end