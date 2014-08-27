module CgminerMonitor
  module Api
    module V1
      class LogController < ActionController::Base
        def last_entries
          limit   = params[:limit] || 1
          entries = CgminerMonitor::Document.document_types.inject({}) do |accumulator, klass|
            accumulator[klass.to_s.downcase.demodulize] = klass.last_entries(limit)
            accumulator
          end

          render :json => entries.as_json
        end
      end
    end
  end
end