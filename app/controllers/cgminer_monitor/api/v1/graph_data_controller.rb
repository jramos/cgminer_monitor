module CgminerMonitor
  module Api
    module V1
      class GraphDataController < ActionController::Base
        before_filter :set_cache_headers

        def local_hashrate
          response = summaries.collect do |summary|
            [
              summary[:created_at].to_i,
              summary[:results].collect do |miner_result|
                miner_result.first[:ghs_5s] rescue 0
              end.sum.round(2),
              summary[:results].collect do |miner_result|
                miner_result.first[:ghs_av] rescue 0
              end.sum.round(2),
              summary[:results].collect do |miner_result|
                miner_result.first[:'device_hardware%'] / 100 rescue 0
              end.sum.round(6),
              summary[:results].collect do |miner_result|
                miner_result.first[:'device_rejected%'] / 100 rescue 0
              end.sum.round(6),
              summary[:results].collect do |miner_result|
                miner_result.first[:'pool_rejected%']   / 100 rescue 0
              end.sum.round(6),
              summary[:results].collect do |miner_result|
                miner_result.first[:'pool_stale%']      / 100 rescue 0
              end.sum.round(6)
            ]
          end

          render :json => response.as_json
        end

        def local_temperature
          response = devs.collect do |device|
            temperatures = device[:results].collect do |miner_result|
              miner_result.first[:temperature].to_f rescue nil
            end.compact

            min_temp = temperatures.min.round(2) rescue nil
            avg_temp = (temperatures.sum / temperatures.count).round(2) rescue nil
            max_temp = temperatures.max.round(2) rescue nil

            [
              device[:created_at].to_i,
              min_temp,
              avg_temp,
              max_temp
            ]
          end

          render :json => response.as_json
        end

        def local_availability
          response = summaries.collect do |summary|
            [
              summary[:created_at].to_i,
              summary[:results].compact.count,
              summary[:results].count
            ]
          end

          render :json => response.as_json
        end

        def miner_hashrate
          miner_id = params[:miner_id] ? params[:miner_id].to_i : nil

          response = if miner_id
            summaries.collect do |summary|
              miner_summary = summary[:results][miner_id].try(:first)

              [
                summary[:created_at].to_i,
                (miner_summary[:ghs_5s] rescue 0).round(2),
                (miner_summary[:ghs_av] rescue 0).round(2),
                (miner_summary[:'device_hardware%'] / 100 rescue 0).round(6),
                (miner_summary[:'device_rejected%'] / 100 rescue 0).round(6),
                (miner_summary[:'pool_rejected%']   / 100 rescue 0).round(6),
                (miner_summary[:'pool_stale%']      / 100 rescue 0).round(6)
              ]
            end
          end

          render :json => response.as_json
        end

        def miner_temperature
          miner_id = params[:miner_id] ? params[:miner_id].to_i : nil

          response = if miner_id
            stats.collect do |stat|
              miner_stats = stat[:results][miner_id] || []
              temperatures = miner_stats.collect do |stat_result|
                stat_result.select{|key, value| key.match('^temp\d') && value > 0 }.values.collect(&:to_f)
              end.flatten

              min_temp = temperatures.min.round(2) rescue nil
              avg_temp = (temperatures.sum / temperatures.count).round(2) rescue nil
              max_temp = temperatures.max.round(2) rescue nil

              unless miner_stats.empty?
                [
                  stat[:created_at].to_i,
                  min_temp,
                  avg_temp,
                  max_temp
                ]
              else
                [
                  stat[:created_at].to_i,
                  0,
                  0,
                  0
                ]
              end
            end
          end

          render :json => response.as_json
        end

        def miner_availability
          miner_id = params[:miner_id] ? params[:miner_id].to_i : nil

          response = if miner_id
            summaries.collect do |summary|
              [
                summary[:created_at].to_i,
                summary[:results][miner_id].try(:count) || 0,
                1
              ]
            end
          end

          render :json => response.as_json
        end

        private

        def set_cache_headers
          expires_in CgminerMonitor::Logger.log_interval.seconds, :public => true
        end

        def devs
          CgminerMonitor::Document::Devs.where(:created_at.gt => created_at_from_range)
        end

        def stats
          CgminerMonitor::Document::Stats.where(:created_at.gt => created_at_from_range)
        end

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