require 'cgminer_api_client'
require 'mongoid'
require 'rails'

require 'cgminer_monitor/document'
require 'cgminer_monitor/engine'
require 'cgminer_monitor/logger'
require 'cgminer_monitor/version'

Mongoid.load!("config/mongoid.yml", ENV['RAILS_ENV'] || :development)

module CgminerMonitor
end

I18n.enforce_available_locales = false