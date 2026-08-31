# frozen_string_literal: true

require 'rails_helper'

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

    it 'carries the product filter inside the signed query' do
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
end
