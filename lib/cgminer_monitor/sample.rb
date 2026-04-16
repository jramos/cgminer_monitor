# frozen_string_literal: true

module CgminerMonitor
  class Sample
    include Mongoid::Document

    # store_in is called PROGRAMMATICALLY at boot (or in test setup),
    # not as a class macro, because:
    # 1. The expire_after value depends on runtime Config (not available at class load)
    # 2. Mongoid passes values straight to the driver without calling Procs
    # 3. create_collection must be called explicitly — lazy creation makes a regular collection

    field :ts,   type: Time
    field :meta, type: Hash
    field :v,    type: Float
  end
end
