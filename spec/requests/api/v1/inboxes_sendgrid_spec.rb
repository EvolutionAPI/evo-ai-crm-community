# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'SendGrid channel via /api/v1/inboxes', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let(:scopes_url) { 'https://api.sendgrid.com/v3/scopes' }
  let(:webhook_url) { 'https://api.sendgrid.com/v3/user/webhooks/event/settings' }
  let(:valid_payload) do
    {
      name: 'SendGrid Inbox',
      channel: {
        type: 'sendgrid',
        api_key: 'SG.secret-key-xyz',
        from_email: 'sender@example.com',
        from_name: 'Test Sender',
        sender_domain: 'example.com'
      }
    }
  end

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    stub_request(:get, scopes_url).to_return(status: 200, body: '{}')
    stub_request(:patch, webhook_url).to_return(status: 200, body: '{}')
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  describe 'POST /api/v1/inboxes' do
    it 'creates a SendGrid channel and exposes only safe channel fields' do
      post '/api/v1/inboxes', params: valid_payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      data = response.parsed_body['data']
      expect(data['channel_type']).to eq('Channel::Sendgrid')
      expect(data['from_email']).to eq('sender@example.com')
      expect(data['api_key_present']).to be(true)
    end

    it 'never returns the api_key in plaintext' do
      post '/api/v1/inboxes', params: valid_payload, headers: headers, as: :json

      data = response.parsed_body['data']
      expect(response.body).not_to include('SG.secret-key-xyz')
      expect(data).not_to have_key('api_key')
      expect(data).not_to have_key('api_key_encrypted')
    end

    it 'returns 422 for an invalid from_email' do
      post '/api/v1/inboxes',
           params: valid_payload.deep_merge(channel: { from_email: 'not-an-email' }),
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'registers the SendGrid webhook and reports it active' do
      post '/api/v1/inboxes', params: valid_payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['data']['webhook_registration_status']).to eq('active')
      expect(a_request(:patch, webhook_url)).to have_been_made
    end

    it 'returns 422 and does not persist the channel when the api_key is rejected' do
      stub_request(:get, scopes_url).to_return(status: 401, body: '{}')

      expect do
        post '/api/v1/inboxes', params: valid_payload, headers: headers, as: :json
      end.not_to change(Channel::Sendgrid, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'persists the channel with a failed webhook status when registration errors' do
      stub_request(:patch, webhook_url).to_return(status: 500, body: 'oops')

      post '/api/v1/inboxes', params: valid_payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['data']['webhook_registration_status']).to eq('failed')
    end
  end

  describe 'PATCH /api/v1/inboxes/:id' do
    def create_inbox
      post '/api/v1/inboxes', params: valid_payload, headers: headers, as: :json
      response.parsed_body['data']['id']
    end

    it 're-runs the smoke test when the api_key is rotated' do
      inbox_id = create_inbox
      WebMock.reset_executed_requests!

      patch "/api/v1/inboxes/#{inbox_id}",
            params: { channel: { api_key: 'SG.rotated-key' } }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(a_request(:get, scopes_url)).to have_been_made.once
    end

    it 'returns 422 when the rotated api_key is rejected' do
      inbox_id = create_inbox
      stub_request(:get, scopes_url).to_return(status: 403, body: '{}')

      patch "/api/v1/inboxes/#{inbox_id}",
            params: { channel: { api_key: 'SG.bad-key' } }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'GET /api/v1/inboxes' do
    it 'lists the SendGrid inbox alongside other email channels' do
      sendgrid = Channel::Sendgrid.create!(api_key: 'SG.key', from_email: 'sg@example.com')
      Inbox.create!(channel: sendgrid, name: 'SG Inbox')
      email = Channel::Email.create!(email: "e-#{SecureRandom.hex(4)}@example.com", forward_to_email: 'fwd@example.com')
      Inbox.create!(channel: email, name: 'Email Inbox')

      get '/api/v1/inboxes', headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      channel_types = response.parsed_body['data'].map { |inbox| inbox['channel_type'] }
      expect(channel_types).to include('Channel::Sendgrid', 'Channel::Email')
    end
  end
end
