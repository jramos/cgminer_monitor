# frozen_string_literal: true

module CgminerMonitor
  module SnapshotQuery
    module_function

    def for_miner(miner:, command:)
      Snapshot.where(miner: miner, command: command).first
    end

    def miners
      # Get the most recent snapshot per miner (regardless of command).
      # Group by miner, take the max fetched_at, and the overall ok status
      # (true if any command succeeded in the most recent poll).
      pipeline = [
        { '$sort' => { 'fetched_at' => -1 } },
        {
          '$group' => {
            '_id' => '$miner',
            'fetched_at' => { '$first' => '$fetched_at' },
            'any_ok' => { '$max' => { '$cond' => ['$ok', 1, 0] } }
          }
        },
        { '$sort' => { '_id' => 1 } }
      ]
      Snapshot.collection.aggregate(pipeline).map do |doc|
        {
          miner: doc['_id'],
          fetched_at: doc['fetched_at'],
          ok: doc['any_ok'] == 1
        }
      end
    end

    def last_poll_at(miner:)
      snapshot = Snapshot.where(miner: miner).order_by(fetched_at: :desc).first
      snapshot&.fetched_at
    end
  end
end
