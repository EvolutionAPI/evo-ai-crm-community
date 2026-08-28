# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Integrations::EvolutionHubController, type: :controller do
  let(:channel_token) { 'hub-token-do-canal' }
  let(:inbox_id) { SecureRandom.uuid }
  let(:hub_client) { instance_double(EvolutionHub::Client) }

  let(:channel) do
    Channel::Whatsapp.new(
      phone_number: '+5511999999999',
      provider: 'whatsapp_cloud',
      provider_config: { 'evolution_hub' => { 'channel_id' => 'hub-ch-1', 'channel_token' => channel_token } }
    )
  end

  let(:inbox) { instance_double(Inbox, id: inbox_id, channel: channel) }

  before do
    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(controller).to receive(:authorize).and_return(true)
    allow(MetaBaseUrl).to receive(:enabled?).and_return(true)
    allow(EvolutionHub::Client).to receive(:new).and_return(hub_client)
    allow(Inbox).to receive(:find).with(inbox_id).and_return(inbox)
  end

  describe 'GET #connect_info' do
    it 'resolves the channel token from the inbox and returns the hub payload' do
      expect(hub_client).to receive(:public_connect_info).with(channel_token).and_return(
        { 'meta_app_id' => 'app-1', 'meta_config_id' => 'cfg-1', 'can_connect' => true }
      )

      get :connect_info, params: { inbox_id: inbox_id }, format: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['meta_config_id']).to eq('cfg-1')
    end

    it 'never uses a token supplied by the caller' do
      expect(hub_client).to receive(:public_connect_info).with(channel_token).and_return({})

      get :connect_info, params: { inbox_id: inbox_id, channel_token: 'token-de-outro-canal' }, format: :json

      expect(response).to have_http_status(:ok)
    end

    it 'returns 404 when the inbox has no hub channel' do
      channel.provider_config = {}

      get :connect_info, params: { inbox_id: inbox_id }, format: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 503 when the hub is disabled' do
      allow(MetaBaseUrl).to receive(:enabled?).and_return(false)

      get :connect_info, params: { inbox_id: inbox_id }, format: :json

      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe 'POST #whatsapp_connect' do
    let(:signup_params) do
      { inbox_id: inbox_id, phone_number_id: '1234', waba_id: '5678', business_id: '9012', auth_code: 'code-abc' }
    end

    it 'forwards the embedded signup result to the hub' do
      expect(hub_client).to receive(:public_whatsapp_connect).with(
        channel_token,
        { phone_number_id: '1234', waba_id: '5678', business_id: '9012',
          auth_code: 'code-abc', connection_mode: 'shared' }
      ).and_return({})

      post :whatsapp_connect, params: signup_params.merge(connection_mode: 'shared'), format: :json

      expect(response).to have_http_status(:ok)
    end

    it 'rejects a payload missing required fields' do
      post :whatsapp_connect, params: signup_params.except(:auth_code), format: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to include('auth_code')
    end

    it 'never leaks the channel token in the error returned to the caller' do
      allow(hub_client).to receive(:public_whatsapp_connect).and_raise(
        EvolutionHub::Client::RequestError.new(
          "Evolution Hub POST #{EvolutionHub::Client::PUBLIC_CONNECT_OP}/whatsapp/connect failed with HTTP 400",
          status: 400, body: '{}'
        )
      )

      post :whatsapp_connect, params: signup_params, format: :json

      expect(response.parsed_body['error']).not_to include(channel_token)
    end

    it 'keeps the hub structured error code instead of a bare HTTP status' do
      allow(hub_client).to receive(:public_whatsapp_connect).and_raise(
        EvolutionHub::Client::RequestError.new(
          'Evolution Hub POST failed with HTTP 403',
          status: 403,
          body: { 'error' => { 'code' => 'PLAN_FORBIDS_SHARED', 'message' => 'plano nao permite' } }.to_json
        )
      )

      post :whatsapp_connect, params: signup_params, format: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['code']).to eq('PLAN_FORBIDS_SHARED')
    end
  end
end
