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

    it 'authorizes the inbox for reading, not for writing' do
      expect(controller).to receive(:authorize).with(inbox, :show?).and_return(true)
      allow(hub_client).to receive(:public_connect_info).and_return({})

      get :connect_info, params: { inbox_id: inbox_id }, format: :json
    end

    # connection_url embeds the channel token; this response reaches the browser.
    it 'strips connection_url from the payload it hands back' do
      allow(hub_client).to receive(:public_connect_info).and_return(
        { 'can_connect' => true, 'meta_app_id' => 'app-1',
          'connection_url' => "https://hub.example/connect/#{channel_token}",
          'owner_locale' => 'pt-BR' }
      )

      get :connect_info, params: { inbox_id: inbox_id }, format: :json

      expect(response.parsed_body).to include('can_connect' => true, 'meta_app_id' => 'app-1')
      expect(response.parsed_body).not_to have_key('connection_url')
      expect(response.body).not_to include(channel_token)
    end

    it 'returns 404 when the inbox has no hub channel' do
      channel.provider_config = {}

      get :connect_info, params: { inbox_id: inbox_id }, format: :json

      expect(response).to have_http_status(:not_found)
    end

    # evolution_hub_meta is a column on facebook/instagram channels only, so an
    # unguarded lookup NoMethodErrors into a 500 instead of "no hub channel".
    it 'returns 404 for a channel type that carries no hub state' do
      allow(inbox).to receive(:channel).and_return(Channel::WebWidget.new)

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
      { inbox_id: inbox_id, phone_number_id: '1234', waba_id: '5678', business_id: '9012',
        auth_code: 'code-abc', connection_mode: 'meta' }
    end

    it 'forwards the embedded signup result to the hub' do
      expect(hub_client).to receive(:public_whatsapp_connect).with(
        channel_token,
        { phone_number_id: '1234', waba_id: '5678', business_id: '9012',
          auth_code: 'code-abc', connection_mode: 'meta' }
      ).and_return({})

      post :whatsapp_connect, params: signup_params, format: :json

      expect(response).to have_http_status(:ok)
    end

    it 'authorizes the inbox for writing' do
      expect(controller).to receive(:authorize).with(inbox, :update?).and_return(true)
      allow(hub_client).to receive(:public_whatsapp_connect).and_return({})

      post :whatsapp_connect, params: signup_params, format: :json
    end

    # The Hub binds connection_mode as required; without it every in-page signup
    # is rejected at the Hub with an opaque 400.
    it 'rejects a payload missing connection_mode' do
      post :whatsapp_connect, params: signup_params.except(:connection_mode), format: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to include('connection_mode')
    end

    it 'rejects a payload missing waba_id' do
      post :whatsapp_connect, params: signup_params.except(:waba_id), format: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to include('waba_id')
    end

    # business_id and auth_code are omitempty on the Hub side; requiring them here
    # turned a legitimate Meta payload into a 400.
    it 'accepts a payload without the fields the hub treats as optional' do
      expect(hub_client).to receive(:public_whatsapp_connect).with(
        channel_token, { phone_number_id: '1234', waba_id: '5678', connection_mode: 'meta' }
      ).and_return({})

      post :whatsapp_connect,
           params: signup_params.except(:business_id, :auth_code), format: :json

      expect(response).to have_http_status(:ok)
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
