# frozen_string_literal: true

module CgminerMonitor
  class Snapshot
    include Mongoid::Document

    store_in collection: "latest_snapshot"

    field :miner,      type: String
    field :command,    type: String
    field :fetched_at, type: Time
    field :ok,         type: Mongoid::Boolean
    field :response,   type: Hash
    field :error,      type: String

    index({ miner: 1, command: 1 }, { unique: true })
    index({ fetched_at: 1 })
  end
end
