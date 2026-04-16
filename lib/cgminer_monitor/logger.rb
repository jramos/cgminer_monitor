# frozen_string_literal: true

require 'json'

module CgminerMonitor
  module Logger
    LEVELS = { 'debug' => 0, 'info' => 1, 'warn' => 2, 'error' => 3 }.freeze

    @output = $stdout
    @format = 'json'
    @level  = 'info'
    @mutex  = Mutex.new

    class << self
      attr_accessor :output, :format, :level

      def info(**fields)
        log('info', fields)
      end

      def warn(**fields)
        log('warn', fields)
      end

      def error(**fields)
        log('error', fields)
      end

      def debug(**fields)
        log('debug', fields)
      end

      private

      def log(level_name, fields)
        return unless LEVELS.fetch(level_name, 0) >= LEVELS.fetch(@level, 1)

        entry = { ts: Time.now.utc.iso8601(3), level: level_name }.merge(fields)

        line = case @format
               when 'text'
                 format_text(entry)
               else
                 JSON.generate(entry)
               end

        @mutex.synchronize { @output.puts(line) }
      end

      def format_text(entry)
        ts = entry.delete(:ts) || entry.delete('ts')
        level = entry.delete(:level) || entry.delete('level')
        event = entry.delete(:event) || entry.delete('event')
        kvs = entry.map { |k, v| "#{k}=#{v}" }.join(' ')
        parts = [ts, level.upcase, event, kvs].compact.reject(&:empty?)
        parts.join(' ')
      end
    end
  end
end
