#!/usr/bin/env ruby
# This is a cron job that ensures cgminer_monitor is running

c = `pidof cgminer_monitor | wc -w`.strip

unless c == '1'
  puts `cgminer_monitor restart`
end