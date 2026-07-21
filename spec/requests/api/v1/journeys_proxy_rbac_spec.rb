# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-2188. The journeys proxy is ONE routed action behind a `*path` glob, so
# everything that makes it safe depends on the real router populating
# params[:path]: which journeys.* permission is demanded, and whether a
# traversing subpath can escape the /journeys prefix. A controller spec injects
# params[:path] by hand and proves neither, so the coverage lives here — and in
# spec/requests/api/v1/*_rbac_spec.rb, which is the path the community-parity
# CI lane actually runs.
RSpec.describe 'Journeys proxy RBAC', type: :request do
  let(:api_url) { 'http://evo-flow.test/api/v1' }
  let(:user) { User.create!(name: 'Journey Probe', email: "journey-#{SecureRandom.hex(4)}@example.com") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch)
      .with('EVO_FLOW_API_URL', EvoFlow::Client::DEFAULT_API_URL).and_return(api_url)
    allow(ENV).to receive(:fetch)
      .with('AUTH_APIKEY_INTEGRATION_LOCAL', nil).and_return('integration-key')
  end

  after { Current.reset }

  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  describe 'the glob actually routes and forwards' do
    it 'GET /api/v1/journeys reaches evo-flow /journeys' do
      grant_permissions('journeys.read')
      stub = stub_request(:get, "#{api_url}/journeys")
             .with(headers: { 'X-Integration-API-Key' => 'integration-key' })
             .to_return(status: 200, body: [].to_json, headers: { 'Content-Type' => 'application/json' })

      get '/api/v1/journeys'

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
    end

    it 'PATCH /api/v1/journeys/:id reaches evo-flow as PATCH' do
      grant_permissions('journeys.update')
      stub = stub_request(:patch, "#{api_url}/journeys/j1")
             .with(body: { name: 'y' }.to_json)
             .to_return(status: 200, body: { id: 'j1' }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

      patch '/api/v1/journeys/j1', params: { name: 'y' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
    end

    it 'POST /api/v1/journeys/:id/toggle-active reaches the nested subpath' do
      grant_permissions('journeys.toggle_active')
      stub = stub_request(:post, "#{api_url}/journeys/j1/toggle-active")
             .to_return(status: 200, body: { isActive: true }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

      post '/api/v1/journeys/j1/toggle-active', params: {}, as: :json

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
    end

    # evo-flow answers 204 on delete; flattening it to 200 with a `null` body
    # breaks the passthrough contract this proxy exists to keep.
    it 'relays evo-flow 204 on delete instead of 200 + null' do
      grant_permissions('journeys.delete')
      stub_request(:delete, "#{api_url}/journeys/j1").to_return(status: 204, body: '')

      delete '/api/v1/journeys/j1'

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
    end
  end

  # Rails unescapes the glob (%2e -> ., %2F -> /) and EvoFlow::Client#join runs
  # URI.join, which resolves `..` per RFC 3986. Unchecked, `journeys/../segments`
  # leaves the journeys prefix and hits any evo-flow endpoint under the service
  # integration key — journeys.read would read segments and campaigns.
  describe 'subpath traversal' do
    it 'refuses an encoded traversal and never calls evo-flow' do
      grant_permissions('journeys.read')

      get '/api/v1/journeys/j1/%2e%2e/%2e%2e/segments'

      expect(response).to have_http_status(:bad_request)
      expect(a_request(:any, /evo-flow\.test/)).not_to have_been_made
    end

    it 'refuses a traversal on a write verb too' do
      grant_permissions('journeys.update', 'journeys.create')

      post '/api/v1/journeys/j1/%2e%2e/%2e%2e/segments/preview', params: {}, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(a_request(:any, /evo-flow\.test/)).not_to have_been_made
    end
  end

  describe 'permission mapping per method + subpath' do
    it 'denies a read without journeys.read' do
      grant_permissions('journeys.create', 'journeys.update')

      get '/api/v1/journeys'

      expect(response).to have_http_status(:forbidden)
      expect(a_request(:any, /evo-flow\.test/)).not_to have_been_made
    end

    it 'denies a create without journeys.create' do
      grant_permissions('journeys.read', 'journeys.update')

      post '/api/v1/journeys', params: { name: 'x' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'denies an update without journeys.update' do
      grant_permissions('journeys.read', 'journeys.create')

      patch '/api/v1/journeys/j1', params: { name: 'y' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'denies a delete without journeys.delete' do
      grant_permissions('journeys.read', 'journeys.update')

      delete '/api/v1/journeys/j1'

      expect(response).to have_http_status(:forbidden)
    end

    it 'denies toggle-active without journeys.toggle_active' do
      grant_permissions('journeys.read', 'journeys.update', 'journeys.create')

      post '/api/v1/journeys/j1/toggle-active', params: {}, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'denies duplicate without journeys.duplicate' do
      grant_permissions('journeys.read', 'journeys.update', 'journeys.create')

      post '/api/v1/journeys/j1/duplicate', params: {}, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    # The sub-resource has to win over the verb, or journeys.manage_sessions
    # gates nothing but the cancel POST: every session read falls to
    # journeys.read and every session delete to journeys.delete.
    it 'demands journeys.manage_sessions to LIST sessions, not journeys.read' do
      grant_permissions('journeys.read')

      get '/api/v1/journeys/j1/sessions'

      expect(response).to have_http_status(:forbidden)
      expect(a_request(:any, /evo-flow\.test/)).not_to have_been_made
    end

    it 'demands journeys.manage_sessions to DELETE a session, not journeys.delete' do
      grant_permissions('journeys.delete')

      delete '/api/v1/journeys/j1/sessions/s-1'

      expect(response).to have_http_status(:forbidden)
    end

    it 'demands journeys.manage_sessions to bulk-delete sessions' do
      grant_permissions('journeys.delete')

      delete '/api/v1/journeys/j1/sessions/bulk/completed'

      expect(response).to have_http_status(:forbidden)
    end

    it 'allows the session surface with journeys.manage_sessions' do
      grant_permissions('journeys.manage_sessions')
      stub = stub_request(:get, "#{api_url}/journeys/j1/sessions")
             .to_return(status: 200, body: [].to_json, headers: { 'Content-Type' => 'application/json' })

      get '/api/v1/journeys/j1/sessions'

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
    end
  end
end
