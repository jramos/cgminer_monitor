# frozen_string_literal: true

require 'securerandom'

module CgminerMonitor
  # Rack middleware that extracts X-Cgminer-Request-Id from the inbound
  # request, falls back to a freshly generated UUID v4 when absent, and
  # stashes the value on env['cgminer_monitor.request_id'] for downstream
  # access (Sinatra before-filters, route handlers, error blocks). Always
  # echoes the value as a response header so callers can correlate without
  # parsing structured logs.
  #
  # Malformed inbound values pass through unchanged — validation would
  # force operators to debug header rewrites at load balancers and adds
  # nothing because dispatch is on string equality, not UUID semantics.
  class RequestId
    HEADER = 'X-Cgminer-Request-Id'
    ENV_KEY = 'cgminer_monitor.request_id'
    RACK_HEADER_KEY = 'HTTP_X_CGMINER_REQUEST_ID'

    def initialize(app)
      @app = app
    end

    def call(env)
      request_id = env[RACK_HEADER_KEY] || SecureRandom.uuid
      env[ENV_KEY] = request_id
      status, headers, body = @app.call(env)
      headers[HEADER] = request_id
      [status, headers, body]
    end
  end
end
