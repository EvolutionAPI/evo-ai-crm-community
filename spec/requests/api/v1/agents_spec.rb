# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-2072 — the AgentsController proxies AI-agent CRUD to evo-core and is gated
# by `ai_agents.*` (repointed from the dead twin `agents.*`). This spec proves
# the repoint end-to-end through the bearer-auth path: we WebMock-stub evo-auth's
# /validate (carries the role key) and /check_permission (answers per key), and
# stub EvoAiCoreService so the proxy never touches the real core. A role holding
# the new `ai_agents.*` gate passes; one holding only the stale `agents.*` (or
# nothing) is forbidden.
RSpec.describe 'Api::V1::Agents (ai_agents gate)', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let!(:user) { User.create!(name: 'Agent Screen User', email: "agents-#{SecureRandom.hex(4)}@example.com") }

  around do |example|
    original_base_url = ENV['EVO_AUTH_SERVICE_URL']
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
  end

  def json_response
    JSON.parse(response.body)
  end

  # Stubs /validate to return the given role key, and /check_permission for the
  # given user to answer `true` only for the permission keys in `granted`.
  def stub_auth(role_key:, granted: [])
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { user: { id: user.id, email: user.email, role: { id: 1, key: role_key, name: role_key } } }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        permission_key = JSON.parse(request.body)['permission_key']
        {
          status: 200,
          body: { success: true, data: { has_permission: granted.include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  before do
    # Proxy target: never hit the real evo-core. Any of these responses is fine —
    # the gate runs (and can deny) before the proxy is reached.
    allow(EvoAiCoreService).to receive(:list_agents).and_return({ 'data' => [] })
    allow(EvoAiCoreService).to receive(:create_agent).and_return({ 'id' => 'agent-1' })
    allow(EvoAiCoreService).to receive(:update_agent).and_return({ 'id' => 'agent-1' })
    allow(EvoAiCoreService).to receive(:delete_agent).and_return(nil)
  end

  context 'with a role that holds the ai_agents.* gate' do
    before do
      stub_auth(role_key: 'custom_ai_manager',
                granted: %w[ai_agents.read ai_agents.create ai_agents.update ai_agents.delete])
    end

    it 'allows index (ai_agents.read)' do
      get '/api/v1/agents', headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(EvoAiCoreService).to have_received(:list_agents)
    end

    it 'allows create (ai_agents.create)' do
      post '/api/v1/agents', params: { name: 'Bot' }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(EvoAiCoreService).to have_received(:create_agent)
    end

    it 'allows update (ai_agents.update)' do
      patch '/api/v1/agents/agent-1', params: { name: 'Bot 2' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(EvoAiCoreService).to have_received(:update_agent)
    end

    it 'allows destroy (ai_agents.delete)' do
      delete '/api/v1/agents/agent-1', headers: headers, as: :json
      expect(response).to have_http_status(:no_content)
      expect(EvoAiCoreService).to have_received(:delete_agent)
    end
  end

  context 'with a role that holds only the stale agents.* gate (proves the repoint)' do
    before { stub_auth(role_key: 'legacy_role', granted: %w[agents.read agents.create agents.update agents.delete]) }

    it 'forbids index' do
      get '/api/v1/agents', headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(EvoAiCoreService).not_to have_received(:list_agents)
    end

    it 'forbids create' do
      post '/api/v1/agents', params: { name: 'Bot' }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(EvoAiCoreService).not_to have_received(:create_agent)
    end
  end

  context 'with a role that holds no relevant grant' do
    before { stub_auth(role_key: 'no_grants', granted: []) }

    it 'forbids index' do
      get '/api/v1/agents', headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
