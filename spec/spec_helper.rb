# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
end

require 'cgminer_monitor'

# WebMock is only pulled into specs that opt in (webhook_client_spec +
# alerts_integration_spec) — not globally, because the existing
# cli_reload_spec boots a real Puma instance and needs localhost net
# connect. The opt-in specs call `require 'webmock/rspec'` directly
# and then `WebMock.disable_net_connect!(allow_localhost: true)` in
# their own `before` blocks.

# Load all support files (mongo_helper, etc.)
require 'cgminer_test_support'
Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.filter_run :focus
  config.run_all_when_everything_filtered = true

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.syntax = :expect
    mocks.verify_partial_doubles = true
  end
end
