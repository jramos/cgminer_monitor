module CgminerMonitor
  module Api
    module V1
      class LogController < ActionController::Base
        def application
          render :text => `tail -n 25 log/cgminer_monitor.log`
        end

        def error
          render :text => `tail -n 25 log/cgminer_monitor.error.log`
        end
      end
    end
  end
end