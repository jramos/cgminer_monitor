# frozen_string_literal: true

module CgminerMonitor
  module SampleQuery
    HASHRATE_METRICS = %w[ghs_5s ghs_av device_hardware_pct device_rejected_pct pool_rejected_pct pool_stale_pct].freeze
    RATE_METRICS = %w[device_hardware_pct device_rejected_pct pool_rejected_pct pool_stale_pct].freeze

    module_function

    def hashrate(miner: nil, since: Time.now - 3600, until_: Time.now)
      scope = time_range_scope(since, until_)
              .where('meta.command' => 'summary', 'meta.sub' => 0, 'meta.metric' => { '$in' => HASHRATE_METRICS })
      scope = scope.where('meta.miner' => miner) if miner

      rows_by_ts = scope.order_by(ts: :asc).group_by { |s| s.ts.to_i }

      rows_by_ts.map do |ts, samples|
        if miner
          values = HASHRATE_METRICS.map { |m| find_metric_value(samples, m) }
        else
          by_metric = samples.group_by { |s| s.meta['metric'] }
          values = HASHRATE_METRICS.map do |m|
            metric_samples = by_metric[m] || []
            next 0.0 if metric_samples.empty?

            total = metric_samples.sum(&:v)
            RATE_METRICS.include?(m) ? (total / metric_samples.size).round(6) : total.round(2)
          end
        end
        [ts] + values
      end
    end

    def temperature(miner: nil, since: Time.now - 3600, until_: Time.now)
      scope = time_range_scope(since, until_)
              .where('meta.command' => { '$in' => %w[devs stats] }, 'meta.metric' => /^temp/)
      scope = scope.where('meta.miner' => miner) if miner

      rows_by_ts = scope.order_by(ts: :asc).group_by { |s| s.ts.to_i }

      rows_by_ts.filter_map do |ts, samples|
        temps = samples.map(&:v).compact
        next if temps.empty?

        [ts, temps.min.round(2), (temps.sum / temps.size).round(2), temps.max.round(2)]
      end
    end

    def availability(miner: nil, since: Time.now - 3600, until_: Time.now)
      scope = time_range_scope(since, until_)
              .where('meta.command' => 'poll', 'meta.metric' => 'ok')
      scope = scope.where('meta.miner' => miner) if miner

      if miner
        scope.order_by(ts: :asc).map { |s| [s.ts.to_i, s.v.to_i] }
      else
        configured = Snapshot.distinct(:miner).length
        rows_by_ts = scope.order_by(ts: :asc).group_by { |s| s.ts.to_i }
        rows_by_ts.map do |ts, samples|
          [ts, samples.count { |s| s.v.to_i == 1 }, configured]
        end
      end
    end

    class << self
      private

      def time_range_scope(since, until_)
        Sample.where(ts: { '$gte' => since, '$lt' => until_ })
      end

      def find_metric_value(samples, metric_name)
        samples.find { |s| s.meta['metric'] == metric_name }&.v || 0.0
      end
    end
  end
end
