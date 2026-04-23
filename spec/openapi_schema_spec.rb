# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# Tightness assertions on the envelope-schema wiring added in 2.1.0.
# The sibling openapi_consistency_spec covers path parity (every route
# documented; no phantom routes). This spec covers the response-body
# shape: the seven endpoints that declared no schema before 2.1.0 now
# each resolve a $ref to one of the two reusable envelope schemas.
#
# Regression target: a future edit that silently drops a $ref — or
# renames SnapshotEnvelope / GraphDataEnvelope — should fail here
# before it ships.
RSpec.describe 'OpenAPI envelope schemas' do
  snapshot_paths = %w[
    /v2/miners/{miner}/summary
    /v2/miners/{miner}/stats
    /v2/miners/{miner}/devices
    /v2/miners/{miner}/pools
  ].freeze

  graph_paths = %w[
    /v2/graph_data/hashrate
    /v2/graph_data/temperature
    /v2/graph_data/availability
  ].freeze

  let(:openapi) do
    YAML.load_file(File.expand_path('../lib/cgminer_monitor/openapi.yml', __dir__))
  end

  def response_ref(openapi, path)
    openapi.dig('paths', path, 'get', 'responses', '200',
                'content', 'application/json', 'schema', '$ref')
  end

  describe 'components.schemas' do
    it 'defines SnapshotEnvelope with ok, response, error' do
      schema = openapi.dig('components', 'schemas', 'SnapshotEnvelope')
      expect(schema).not_to be_nil
      expect(schema['properties'].keys).to include('ok', 'response', 'error')
      expect(schema['required']).to include('ok')
    end

    it 'defines GraphDataEnvelope with fields, data' do
      schema = openapi.dig('components', 'schemas', 'GraphDataEnvelope')
      expect(schema).not_to be_nil
      expect(schema['properties'].keys).to include('fields', 'data')
      expect(schema['required']).to include('fields', 'data')
    end
  end

  describe 'snapshot endpoints' do
    snapshot_paths.each do |path|
      it "#{path} 200 response references SnapshotEnvelope" do
        expect(response_ref(openapi, path)).to eq('#/components/schemas/SnapshotEnvelope')
      end
    end
  end

  describe 'graph_data endpoints' do
    graph_paths.each do |path|
      it "#{path} 200 response references GraphDataEnvelope" do
        expect(response_ref(openapi, path)).to eq('#/components/schemas/GraphDataEnvelope')
      end
    end
  end
end
