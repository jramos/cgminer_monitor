# frozen_string_literal: true

require 'cgminer_api_client'
require 'mongoid'
require 'active_support/core_ext/string/inflections'

require 'cgminer_monitor/errors'
require 'cgminer_monitor/daemon'
require 'cgminer_monitor/document'
require 'cgminer_monitor/logger'
require 'cgminer_monitor/version'

module CgminerMonitor
end
