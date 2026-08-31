# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# CRM-493: the authenticated config surface of the purchase-webhook ingress —
# the pipeline screen's platform picker (providers) and the signed URL minting.
# The minted URL must agree with the ingress: same MAC, same secret rules.
RSpec.describe 'Api::V1::PurchaseWebhooks', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  let!(:user) { User.create!(name: 'Config User', email: "cfg-#{SecureRandom.hex(4)}@example.com") }
  let!(:pipeline) { Pipeline.create!(name: "Compras #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user) }
  let!(:entry_stage) { pipeline.pipeline_stages.create!(name: 'Entrada', position: 1) }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    ENV['FRONTEND_URL'] = 'https://app.evo.test'
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load)
      .with('PURCHASE_WEBHOOK_SECRET_CAKTO', nil).and_return('cakto-token')
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    ENV.delete('FRONTEND_URL')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'GET /api/v1/purchase_webhooks/providers' do
    it 'lists every registered provider with its configured flag and the destination-secret flag' do
      get '/api/v1/purchase_webhooks/providers', headers: headers

      expect(response).to have_http_status(:ok)
      providers = json_response.dig('data', 'providers')
      by_name = providers.index_by { |p| p['provider'] }

      expect(by_name.keys).to include('virtu', 'hotmart', 'kiwify', 'cakto')
      expect(by_name['cakto']['configured']).to be(true)
      expect(by_name['hotmart']['configured']).to be(false)
      expect(by_name['kiwify']['requires_destination_secret']).to be(true)
      expect(by_name['cakto']['requires_destination_secret']).to be(false)
      expect(json_response.dig('data', 'destination_secret_configured')).to be(false)
    end
  end

  describe 'GET /api/v1/purchase_webhooks/url' do
    it 'mints a URL the ingress accepts (same MAC over the same values)' do
      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: pipeline.id }, headers: headers

      expect(response).to have_http_status(:ok)
      url = json_response.dig('data', 'url')
      expect(url).to start_with("https://app.evo.test/api/v1/webhooks/purchases/cakto?")

      expected_mac = Webhooks::PurchaseDestinationMac.mint(
        'cakto-token', 'cakto',
        { 'evo_tenant' => '', 'pipeline_id' => pipeline.id.to_s, 'product' => '' }
      )
      expect(url).to include("d=#{expected_mac}")
      expect(json_response.dig('data', 'host_kind')).to eq('global')
    end

    it 'signs with the destination secret when configured' do
      allow(GlobalConfigService).to receive(:load)
        .with(Webhooks::PurchaseDestinationMac::SECRET_KEY, nil).and_return('dest-secret')

      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: pipeline.id }, headers: headers

      expected_mac = Webhooks::PurchaseDestinationMac.mint(
        'dest-secret', 'cakto',
        { 'evo_tenant' => '', 'pipeline_id' => pipeline.id.to_s, 'product' => '' }
      )
      expect(json_response.dig('data', 'url')).to include("d=#{expected_mac}")
    end

    it 'refuses the config errors with distinct reasons' do
      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'nope', pipeline_id: pipeline.id }, headers: headers
      expect(response).to have_http_status(:not_found)

      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: SecureRandom.uuid }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('PIPELINE_NOT_FOUND')

      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'hotmart', pipeline_id: pipeline.id }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('CREDENTIAL_MISSING')

      allow(GlobalConfigService).to receive(:load)
        .with('PURCHASE_WEBHOOK_SECRET_KIWIFY', nil).and_return('pub-key')
      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'kiwify', pipeline_id: pipeline.id }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('DESTINATION_SECRET_REQUIRED')
    end

    it 'refuses a stage-less pipeline (the URL would fail on every delivery)' do
      empty = Pipeline.create!(name: "Vazio #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user)

      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: empty.id }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('PIPELINE_WITHOUT_STAGES')
    end

    it 'refuses when no host resolves (the URL would be relative)' do
      ENV['FRONTEND_URL'] = ''

      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: pipeline.id }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('HOST_NOT_CONFIGURED')
    end

    it 'carries the product override inside the signed query (stamps the card, never filters)' do
      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: pipeline.id, product: 'curso-x' },
          headers: headers

      url = json_response.dig('data', 'url')
      expect(url).to include('product=curso-x')
      expected_mac = Webhooks::PurchaseDestinationMac.mint(
        'cakto-token', 'cakto',
        { 'evo_tenant' => '', 'pipeline_id' => pipeline.id.to_s, 'product' => 'curso-x' }
      )
      expect(url).to include("d=#{expected_mac}")
    end
  end

  # The examples above authenticate with a service token, which EvoPermissionConcern
  # short-circuits — so neither the permission nor the pipeline policy is exercised
  # there. These resolve a real Current.user through evo-auth.
  describe 'GET /api/v1/purchase_webhooks/url as a real user' do
    let(:auth_url) { 'http://auth.test' }
    let(:bearer) { { 'Authorization' => 'Bearer test-bearer-token' } }
    let!(:outsider) { User.create!(name: 'Outsider', email: "out-#{SecureRandom.hex(4)}@example.com") }
    let(:private_pipeline) do
      Pipeline.create!(name: "Privado #{SecureRandom.hex(4)}", pipeline_type: 'sales',
                       visibility: :private, created_by: user).tap do |p|
        p.pipeline_stages.create!(name: 'Entrada', position: 1)
      end
    end

    around do |example|
      original = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
      ENV['EVO_AUTH_SERVICE_URL'] = auth_url
      Rails.cache.clear
      Current.reset
      example.run
      Rails.cache.clear
      Current.reset
      ENV['EVO_AUTH_SERVICE_URL'] = original
    end

    def stub_auth(as_user, granted:)
      stub_request(:post, "#{auth_url}/api/v1/auth/validate")
        .to_return(status: 200,
                   body: { success: true,
                           data: { user: { id: as_user.id, email: as_user.email,
                                           role: { id: 1, key: 'r', name: 'r' } } } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
      stub_request(:post, "#{auth_url}/api/v1/users/#{as_user.id}/check_permission")
        .to_return do |req|
          key = JSON.parse(req.body)['permission_key']
          { status: 200, body: { success: true, data: { has_permission: granted.include?(key) } }.to_json,
            headers: { 'Content-Type' => 'application/json' } }
        end
    end

    it 'refuses a caller without pipelines.update (403)' do
      stub_auth(user, granted: [])

      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: pipeline.id }, headers: bearer

      expect(response).to have_http_status(:forbidden)
    end

    # EVO-2204: the permission is global, the funnel is not. Without the policy a
    # manager could point purchases at a private funnel they cannot even see.
    # 401, not 403: RequestExceptionHandler's around_action catches the Pundit
    # refusal before the rescue_from that would answer 403.
    it 'refuses a private pipeline the caller cannot see, even with pipelines.update' do
      stub_auth(outsider, granted: %w[pipelines.update])

      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: private_pipeline.id }, headers: bearer

      expect(response).to have_http_status(:unauthorized)
    end

    it 'mints for the owner of that same private pipeline' do
      stub_auth(user, granted: %w[pipelines.update])

      get '/api/v1/purchase_webhooks/url',
          params: { provider: 'cakto', pipeline_id: private_pipeline.id }, headers: bearer

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'url')).to start_with('https://app.evo.test/')
    end
  end
end
