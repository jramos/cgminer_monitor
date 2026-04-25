# frozen_string_literal: true

require 'spec_helper'

describe CgminerMonitor::RequestId do
  let(:inner_app) { ->(env) { [200, {}, [env['cgminer_monitor.request_id']]] } }
  let(:middleware) { described_class.new(inner_app) }

  context 'when the request carries X-Cgminer-Request-Id' do
    it "propagates the inbound value to env['cgminer_monitor.request_id']" do
      env = { 'HTTP_X_CGMINER_REQUEST_ID' => 'a1b2c3d4-0000-0000-0000-000000000000' }
      _, _, body = middleware.call(env)
      expect(body.first).to eq('a1b2c3d4-0000-0000-0000-000000000000')
    end

    it 'echoes the value in the response header' do
      env = { 'HTTP_X_CGMINER_REQUEST_ID' => 'a1b2c3d4-0000-0000-0000-000000000000' }
      _, headers, = middleware.call(env)
      expect(headers['X-Cgminer-Request-Id']).to eq('a1b2c3d4-0000-0000-0000-000000000000')
    end
  end

  context 'when the request lacks the header' do
    it 'generates a fresh UUID v4' do
      _, _, body = middleware.call({})
      expect(body.first).to match(
        /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      )
    end

    it 'sets the response header to the same generated UUID (no value drift)' do
      _, headers, body = middleware.call({})
      expect(headers['X-Cgminer-Request-Id']).to eq(body.first)
    end
  end

  context 'when the inbound header is malformed' do
    # Pass-through; validation would force operators to debug header rewrites
    # at load balancers and adds nothing because dispatch is on string equality.
    it 'propagates the malformed value untouched' do
      env = { 'HTTP_X_CGMINER_REQUEST_ID' => 'not-a-uuid' }
      _, _, body = middleware.call(env)
      expect(body.first).to eq('not-a-uuid')
    end

    it 'does not enable header injection on response (CR/LF in inbound value)' do
      # Rack and Puma sanitize CR/LF before the middleware sees it, but
      # belt-and-braces — confirm no FakeHeader appears in our response.
      env = { 'HTTP_X_CGMINER_REQUEST_ID' => "x\r\nFakeHeader: y" }
      _, headers, = middleware.call(env)
      expect(headers).not_to have_key('FakeHeader')
    end
  end
end
