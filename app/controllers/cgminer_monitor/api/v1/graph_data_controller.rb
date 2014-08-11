module CgminerMonitor
  module Api
    module V1
      class GraphDataController < ActionController::Base
        def index
          render :json => []
        end
      end
    end
  end
end