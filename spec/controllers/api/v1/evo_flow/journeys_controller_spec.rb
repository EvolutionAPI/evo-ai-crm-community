# frozen_string_literal: true

require 'rails_helper'

# EVO-2188: the CRM proxies `segments` to evo-flow but not `journeys`, so the
# journey builder got 404/405. This controller is the generic passthrough proxy,
# gated by the journeys.* permissions (hardening, like SegmentsController/EVO-1938).
#
# Routing through the real glob (and the permission table per subpath) is covered
# by spec/requests/api/v1/journeys_proxy_rbac_spec.rb — a controller spec injects
# params[:path] by hand and cannot prove either.
RSpec.describe Api::V1::EvoFlow::JourneysController, type: :controller do
  let(:fake_client) { instance_double(EvoFlow::Client) }

  before do
    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(EvoFlow::Client).to receive(:new).and_return(fake_client)
  end

  after { Current.reset }

  describe 'proxying to evo-flow (authorized via service token)' do
    before { Current.service_authenticated = true } # bypasses the permission gate

    it 'forwards the caller tenant and identity to evo-flow (multi-tenant scope)' do
      request.headers['X-Evo-Tenant-Id'] = '2c013165-3992-4e6f-ba0d-4b6cb768a5d6'
      request.headers['Authorization'] = 'Bearer user-jwt'
      allow(fake_client).to receive(:request).and_return([200, {}])

      get :proxy

      expect(EvoFlow::Client).to have_received(:new).with(
        extra_headers: { 'X-Evo-Tenant-Id' => '2c013165-3992-4e6f-ba0d-4b6cb768a5d6',
                         'Authorization' => 'Bearer user-jwt' }
      )
    end

    it 'sends no passthrough header when the caller sent none (single-tenant)' do
      allow(fake_client).to receive(:request).and_return([200, {}])

      get :proxy

      expect(EvoFlow::Client).to have_received(:new).with(extra_headers: {})
    end

    it 'GET /journeys forwards to the client and returns the response' do
      allow(fake_client).to receive(:request).with(:get, '/journeys', query: anything)
                                             .and_return([200, { 'items' => [] }])
      get :proxy
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq('items' => [])
    end

    it 'POST /journeys relays evo-flow 201' do
      allow(fake_client).to receive(:request)
        .with(:post, '/journeys', payload: hash_including('name' => 'x'))
        .and_return([201, { 'id' => 'j1' }])
      post :proxy, body: { name: 'x', flowData: { nodes: [] } }.to_json, as: :json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)).to eq('id' => 'j1')
    end

    it 'PATCH /journeys/:id forwards as PATCH (the update path)' do
      expect(fake_client).to receive(:request)
        .with(:patch, '/journeys/j1', payload: hash_including('name' => 'y'))
        .and_return([200, { 'id' => 'j1' }])
      patch :proxy, params: { path: 'j1' }, body: { name: 'y' }.to_json, as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'DELETE /journeys/:id relays evo-flow 204 as 204, not 200 with a null body' do
      expect(fake_client).to receive(:request).with(:delete, '/journeys/j1').and_return([204, nil])
      delete :proxy, params: { path: 'j1' }
      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
    end

    it 'relays the 201 evo-flow answers on duplicate (not a flattened 200)' do
      allow(fake_client).to receive(:request).and_return([201, { 'id' => 'j2' }])
      post :proxy, params: { path: 'j1/duplicate' }, body: {}.to_json, as: :json
      expect(response).to have_http_status(:created)
    end

    # Rails wraps a top-level JSON array as { "_json" => [...] }; evo-flow's
    # POST /journeys/:id/variables binds a bare array.
    it 'unwraps an array body instead of forwarding { _json: [...] }' do
      expect(fake_client).to receive(:request)
        .with(:post, '/journeys/j1/variables', payload: [{ 'id' => 'v1', 'name' => 'n', 'type' => 'text' }])
        .and_return([200, []])
      post :proxy, params: { path: 'j1/variables' },
                   body: [{ id: 'v1', name: 'n', type: 'text' }].to_json, as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'passes evo-flow errors through with their status' do
      err = EvoFlow::HTTPError.new('bad', 422, nil)
      allow(fake_client).to receive(:request).and_raise(err)
      get :proxy
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rejects a payload deeper than the nesting cap' do
      deep = (1..30).reduce({ 'leaf' => true }) { |acc, _| { 'n' => acc } }
      expect(fake_client).not_to receive(:request)
      post :proxy, body: deep.to_json, as: :json
      expect(response).to have_http_status(:payload_too_large)
    end

    # URI.join resolves `..`, so an unchecked subpath would leave /journeys and
    # reach any evo-flow endpoint under the service integration key.
    it 'refuses a traversing subpath before touching evo-flow' do
      expect(fake_client).not_to receive(:request)
      get :proxy, params: { path: 'j1/../../segments' }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'permission gating (EVO-2188)' do
    let(:current_user) { double('User', id: 'user-1') }

    before do
      Current.service_authenticated = false
      Current.user = current_user
      Current.evo_permission_cache = {}
      allow(EvoExtensionPoints::RuntimeContext).to receive(:current_scope_id).and_return(nil)
    end

    def deny(permission)
      Current.evo_permission_cache["user:user-1::#{permission}"] = false
    end

    def allow_perm(permission)
      Current.evo_permission_cache["user:user-1::#{permission}"] = true
    end

    it 'GET requires journeys.read -> 403 when missing, no client call' do
      deny('journeys.read')
      expect(fake_client).not_to receive(:request)
      get :proxy
      expect(response).to have_http_status(:forbidden)
    end

    it 'GET is allowed when journeys.read is granted' do
      allow_perm('journeys.read')
      allow(fake_client).to receive(:request).and_return([200, { 'items' => [] }])
      get :proxy
      expect(response).to have_http_status(:ok)
    end

    it 'POST /journeys requires journeys.create' do
      deny('journeys.create')
      expect(fake_client).not_to receive(:request)
      post :proxy, body: {}.to_json, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it 'PATCH requires journeys.update' do
      deny('journeys.update')
      expect(fake_client).not_to receive(:request)
      patch :proxy, params: { path: 'j1' }, body: {}.to_json, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it 'DELETE requires journeys.delete' do
      deny('journeys.delete')
      expect(fake_client).not_to receive(:request)
      delete :proxy, params: { path: 'j1' }
      expect(response).to have_http_status(:forbidden)
    end

    it 'a toggle-active subpath requires journeys.toggle_active' do
      deny('journeys.toggle_active')
      expect(fake_client).not_to receive(:request)
      post :proxy, params: { path: 'j1/toggle-active' }, body: {}.to_json, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    # The sub-resource decides before the verb does: keying off the verb first
    # made journeys.manage_sessions unreachable for every session read/delete.
    it 'reading sessions requires journeys.manage_sessions, not journeys.read' do
      allow_perm('journeys.read')
      deny('journeys.manage_sessions')
      expect(fake_client).not_to receive(:request)
      get :proxy, params: { path: 'j1/sessions' }
      expect(response).to have_http_status(:forbidden)
    end

    it 'deleting a session requires journeys.manage_sessions, not journeys.delete' do
      allow_perm('journeys.delete')
      deny('journeys.manage_sessions')
      expect(fake_client).not_to receive(:request)
      delete :proxy, params: { path: 'j1/sessions/s-1' }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
