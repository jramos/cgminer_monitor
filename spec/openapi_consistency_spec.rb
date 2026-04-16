# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe 'OpenAPI consistency' do
  let(:openapi_path) { File.expand_path('../lib/cgminer_monitor/openapi.yml', __dir__) }
  let(:openapi) { YAML.safe_load_file(openapi_path) }

  # Extract documented paths from openapi.yml.
  # Normalizes OpenAPI path params {miner} to Sinatra :miner style.
  let(:documented_routes) do
    openapi['paths'].flat_map do |path, methods|
      methods.keys.map do |verb|
        sinatra_path = path.gsub(/\{(\w+)\}/, ':\1')
        [verb.upcase, sinatra_path]
      end
    end.to_set
  end

  # Extract registered routes from HttpApp.
  # Sinatra 4.x stores routes as { "GET" => [[Mustermann::Pattern, ...], ...] }
  # Mustermann patterns respond to .to_s returning the original path string.
  let(:registered_routes) do
    CgminerMonitor::HttpApp.routes.each_with_object(Set.new) do |(verb, route_list), set|
      next if %w[HEAD OPTIONS].include?(verb)

      route_list.each do |route|
        # route[0] is a Mustermann::Sinatra pattern — .to_s gives the path string
        path = route[0].to_s
        set << [verb, path]
      end
    end
  end

  it 'documents every registered route' do
    undocumented = registered_routes - documented_routes
    expect(undocumented).to be_empty,
                            "Routes registered in HttpApp but missing from openapi.yml:\n" \
                            "#{undocumented.map { |v, p| "  #{v} #{p}" }.join("\n")}"
  end

  it 'does not document phantom routes' do
    phantom = documented_routes - registered_routes
    expect(phantom).to be_empty,
                       "Routes documented in openapi.yml but not registered in HttpApp:\n" \
                       "#{phantom.map { |v, p| "  #{v} #{p}" }.join("\n")}"
  end
end
