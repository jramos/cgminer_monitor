module CgminerMonitor
  module Api
    module V1
      class PingController < ActionController::Base
        def index
          render :json => {
            :timestamp => Time.now.to_i,
            :status    => CgminerMonitor::Daemon.status
          }
        end
      end
    end
  end
end