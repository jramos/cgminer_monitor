module CgminerMonitor
  module Api
    module V1
      class GraphDataController < ActionController::Base
        def devs
          render :json => []
        end

        def pools
          render :json => []
        end

        def stats
          render :json => []
        end

        def summary
          render :json => []
        end
      end
    end
  end
end