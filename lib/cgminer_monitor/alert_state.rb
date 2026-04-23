# frozen_string_literal: true

module CgminerMonitor
  class AlertState
    include Mongoid::Document

    store_in collection: "alert_states"

    # Composite string _id ("#{miner}|#{rule}") enforces uniqueness of
    # (miner, rule) through Mongo's implicit _id index — no secondary
    # unique index needed. Default lambda evaluates at build time so
    # upsert-on-save can key off the composite id.
    field :_id, type: String, overwrite: true,
                default: -> { "#{miner}|#{rule}" }

    field :miner, type: String
    field :rule, type: String
    field :state, type: String
    field :threshold, type: Float
    field :last_observed, type: Float
    field :last_fired_at, type: Time
    field :last_transition_at, type: Time
  end
end
