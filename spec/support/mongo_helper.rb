# frozen_string_literal: true

# Configure Mongoid for the test environment.
# Requires a running MongoDB instance (docker run -d -p 27017:27017 mongo:7).
Mongoid.configure do |config|
  config.clients.default = {
    uri: ENV.fetch('CGMINER_MONITOR_MONGO_URL', 'mongodb://localhost:27017/cgminer_monitor_test')
  }
end

# Sample/Snapshot bootstrap and cleanup hooks are added in Task 3
# after the models exist.

module MongoTestHelpers
  def assert_time_series_collection!(collection_name)
    client = Mongoid.default_client
    info = client.database.list_collections(filter: { name: collection_name }).first
    expect(info).not_to be_nil, "Collection '#{collection_name}' does not exist"
    expect(info['type']).to eq('timeseries'),
                            "Expected '#{collection_name}' to be timeseries, got '#{info['type']}'"
  end
end

RSpec.configure do |config|
  config.include MongoTestHelpers
end
