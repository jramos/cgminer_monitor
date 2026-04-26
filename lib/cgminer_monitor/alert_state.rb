# frozen_string_literal: true

module CgminerMonitor
  class AlertState
    include Mongoid::Document

    store_in collection: "alert_states"

    # Composite string _id ("#{miner}|#{rule}") enforces uniqueness of
    # (miner, rule) via Mongo's implicit _id index — no secondary
    # unique index needed. A before_validation callback derives _id
    # from miner+rule so both the evaluator's `find_or_initialize_by`
    # call path (which passes _id explicitly) and direct `create!`
    # calls from tests work without every caller remembering to
    # construct the id.
    field :_id, type: String, overwrite: true

    field :miner, type: String
    field :rule, type: String
    field :state, type: String
    field :threshold, type: Float
    field :last_observed, type: Float
    # Composite-rule observed snapshot. Built-in rules pass nil here
    # (their scalar reading lives in `last_observed`). Composites pass
    # a string-keyed Hash like { "ghs_5s" => 450.5, "temp_max" => 82.3 }.
    # Mongoid round-trips Hash via BSON document — keep keys as Strings
    # to avoid Symbol↔String coercion surprises across saves.
    field :last_observed_components, type: Hash
    field :last_fired_at, type: Time
    field :last_transition_at, type: Time

    before_validation :ensure_composite_id

    def self.composite_id(miner, rule)
      "#{miner}|#{rule}"
    end

    private

    def ensure_composite_id
      return if _id.is_a?(String) && !_id.empty?

      self._id = self.class.composite_id(miner, rule) if miner && rule
    end
  end
end
