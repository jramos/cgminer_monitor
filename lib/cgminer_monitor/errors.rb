# frozen_string_literal: true

module CgminerMonitor
  class Error < StandardError; end
  class ConfigError < Error; end
  class StorageError < Error; end
  class PollError < Error; end
end
