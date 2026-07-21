# frozen_string_literal: true

require 'rails_helper'

# EVO-2188: the CRM proxies `segments` to evo-flow but not `journeys`, so the
# journey builder got 404/405. This controller is the generic passthrough proxy,
# gated by the journeys.* permissions (hardening, like SegmentsController/EVO-1938).
RSpec.describe Api::V1::EvoFlow::JourneysController, type: :controller do
  let(:fake_client) { instance_double(EvoFlow::Client) }

  before do
    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(EvoFlow::Client).to receive(:new).and_return(fake_client)
  end

  after { Current.reset }

  describe 'proxying to evo-flow (authorized via service token)' do
    before { Current.service_authenticated = true } # bypasses the permission gate

    it 'GET /journeys forwards to client.get and returns the response' do
      allow(fake_client).to receive(:get).with('/journeys', anything).and_return('items' => [])
      get :proxy
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq('items' => [])
    end

    it 'POST /journeys forwards to client.post and returns 201' do
      allow(fake_client).to receive(:post).with('/journeys', hash_including('name' => 'x')).and_return('id' => 'j1')
      post :proxy, body: { name: 'x', flowData: { nodes: [] } }.to_json, as: :json
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)).to eq('id' => 'j1')
    end

    it 'PATCH /journeys/:id forwards to client.patch (the update path)' do
      expect(fake_client).to receive(:patch).with('/journeys/j1', hash_including('name' => 'y')).and_return('id' => 'j1')
      patch :proxy, params: { path: 'j1' }, body: { name: 'y' }.to_json, as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'DELETE /journeys/:id forwards to client.delete' do
      expect(fake_client).to receive(:delete).with('/journeys/j1').and_return('deleted' => true)
      delete :proxy, params: { path: 'j1' }
      expect(response).to have_http_status(:ok)
    end

    it 'passes evo-flow errors through with their status' do
      err = EvoFlow::HTTPError.new('bad', 422, nil)
      allow(fake_client).to receive(:get).and_raise(err)
      get :proxy
      expect(response).to have_http_status(:unprocessable_content)
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
      expect(fake_client).not_to receive(:get)
      get :proxy
      expect(response).to have_http_status(:forbidden)
    end

    it 'GET is allowed when journeys.read is granted' do
      allow_perm('journeys.read')
      allow(fake_client).to receive(:get).and_return('items' => [])
      get :proxy
      expect(response).to have_http_status(:ok)
    end

    it 'POST /journeys requires journeys.create' do
      deny('journeys.create')
      expect(fake_client).not_to receive(:post)
      post :proxy, body: {}.to_json, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it 'PATCH requires journeys.update' do
      deny('journeys.update')
      expect(fake_client).not_to receive(:patch)
      patch :proxy, params: { path: 'j1' }, body: {}.to_json, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it 'DELETE requires journeys.delete' do
      deny('journeys.delete')
      expect(fake_client).not_to receive(:delete)
      delete :proxy, params: { path: 'j1' }
      expect(response).to have_http_status(:forbidden)
    end

    it 'a toggle-active subpath requires journeys.toggle_active' do
      deny('journeys.toggle_active')
      expect(fake_client).not_to receive(:post)
      post :proxy, params: { path: 'j1/toggle-active' }, body: {}.to_json, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
