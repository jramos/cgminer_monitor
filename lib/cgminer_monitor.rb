# frozen_string_literal: true

require 'cgminer_api_client'
require 'mongoid'
require 'active_support/core_ext/string/inflections'

require 'cgminer_monitor/errors'
require 'cgminer_monitor/sample'
require 'cgminer_monitor/snapshot'
require 'cgminer_monitor/sample_query'
require 'cgminer_monitor/snapshot_query'
require 'cgminer_monitor/version'

module CgminerMonitor
end
