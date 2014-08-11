module CgminerMonitor
  module Api
    module V1
      class GraphDataController < ActionController::Base
        def local_hashrate
          response = summaries.collect do |summary|
            [
              summary[:created_at].to_i,
              summary[:results].collect do |miner_result|
                miner_result.first[:ghs_5s] rescue 0
              end.sum
            ]
          end

          render :json => response.as_json
        end

        def miner_hashrate
          miner_id = params[:miner_id] ? params[:miner_id].to_i : nil

          if miner_id
            response = summaries.collect do |summary|
              [
                summary[:created_at].to_i,
                (summary[:results][miner_id].first[:ghs_5s] rescue nil)
              ] if summary[:results][miner_id]
            end
          end

          render :json => response.as_json
        end

        private

        def summaries
          CgminerMonitor::Document::Summary.where(:created_at.gt => created_at_from_range)
        end

        def created_at_from_range
          case params[:range]
            when 'last_hour'
              Time.now - 1.hour
            when 'last_day'
              Time.now - 1.day
            when 'last_week'
              Time.now - 1.week
            when 'last_month'
              Time.now - 1.month
            when 'last_year'
              Time.now - 1.year
            else
              Time.now - 1.hour
          end
        end
      end
    end
  end
end