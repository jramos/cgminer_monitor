module CgminerMonitor
  module Api
    module V1
      class GraphDataController < ActionController::Base
        def local_hashrate
          response = summaries.collect do |summary|
            [
              summary[:created_at].to_i,
              summary[:results].collect do |miner_result|
                miner_result.first[:ghs_5s].round(2) rescue 0
              end.sum,
              summary[:results].collect do |miner_result|
                (miner_result.first[:ghs_5s] * miner_result.first[:'pool_rejected%'] / 100).round(2) rescue 0
              end.sum
            ]
          end

          render :json => response.as_json
        end

        def miner_hashrate
          miner_id = params[:miner_id] ? params[:miner_id].to_i : nil

          response = if miner_id
            summaries.collect do |summary|
              miner_summary = summary[:results][miner_id].first
              [
                summary[:created_at].to_i,
                (miner_summary[:ghs_5s].round(2) rescue nil),
                ((miner_summary[:ghs_5s] * miner_summary[:'pool_rejected%'] / 100).round(2) rescue nil)
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