# frozen_string_literal: true

# Configure Mongoid for the test environment.
# Requires a running MongoDB instance (docker run -d -p 27017:27017 mongo:7).
Mongoid.configure do |config|
  config.clients.default = {
    uri: ENV.fetch('CGMINER_MONITOR_MONGO_URL', 'mongodb://localhost:27017/cgminer_monitor_test')
  }
end

# Bootstrap the Sample time-series collection.
# In production this is done by CgminerMonitor::Server#run with Config values;
# in tests we use a fixed 1-day retention.
CgminerMonitor::Sample.store_in(
  collection: "samples",
  collection_options: {
    time_series: {
      timeField: "ts",
      metaField: "meta",
      granularity: "minutes"
    },
    expire_after: 86_400
  }
)

module MongoTestHelpers
  def assert_time_series_collection!(collection_name)
    client = Mongoid.default_client
    info = client.database.list_collections(filter: { name: collection_name }).first
    expect(info).not_to be_nil, "Collection '#{collection_name}' does not exist"
    expect(info['type']).to eq('timeseries'),
                            "Expected '#{collection_name}' to be timeseries, got '#{info['type']}'"
  end

  def insert_samples(*rows)
    CgminerMonitor::Sample.collection.insert_many(rows.flatten)
  end

  def upsert_snapshot(miner:, command:, ok: true, response: {}, error: nil,
                      fetched_at: Time.now.utc)
    CgminerMonitor::Snapshot.collection.update_one(
      { "miner" => miner, "command" => command },
      { "$set" => { "fetched_at" => fetched_at, "ok" => ok, "response" => response, "error" => error } },
      upsert: true
    )
  end

  def build_sample(miner:, command:, metric:, value:, sub: 0, ts: Time.now.utc)
    { ts: ts, meta: { "miner" => miner, "command" => command, "sub" => sub, "metric" => metric }, v: value.to_f }
  end
end

RSpec.configure do |config|
  config.include MongoTestHelpers

  config.before(:suite) do
    db = Mongoid.default_client.database
    db[:samples].drop
    db[:latest_snapshot].drop
    db[:alert_states].drop
    CgminerMonitor::Sample.create_collection
    CgminerMonitor::Snapshot.create_indexes
    CgminerMonitor::AlertState.create_indexes
  end

  config.after do
    CgminerMonitor::Sample.collection.delete_many({})
    CgminerMonitor::Snapshot.collection.delete_many({})
    CgminerMonitor::AlertState.collection.delete_many({})
  end
end
