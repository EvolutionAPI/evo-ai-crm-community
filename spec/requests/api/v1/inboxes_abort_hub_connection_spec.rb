# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# The Hub channel is created BEFORE the Meta OAuth round-trip, so a cancelled
# signup leaves an inbox that never connected on both sides. The connect button
# discards it through this endpoint; the guard here is what keeps the discard
# from ever touching a channel the Hub already activated.
RSpec.describe 'Api::V1::Inboxes abort hub connection', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let!(:user) { User.create!(name: 'Hub Operator', email: "hub-#{SecureRandom.hex(4)}@example.com") }

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

  def stub_auth(role_key: 'agent', granted: [])
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

  # Hub metadata shaped exactly like EvolutionHub::InboxBuilder leaves it after
  # POST /channels and before the operator finishes the Meta signup.
  def hub_channel(status:, linked: false)
    hub_block = {
      'channel_id' => "hub-ch-#{SecureRandom.hex(4)}",
      'channel_token' => 'hub-token',
      'webhook_id' => 'hub-wh-1',
      'public_link' => 'https://hub.test/connect/hub-token',
      'status' => status
    }
    hub_block['linked'] = true if linked

    Channel::Whatsapp.create!(
      phone_number: "+5511#{rand(10**9)}",
      provider: 'whatsapp_cloud',
      provider_config: { 'api_key' => '', 'phone_number_id' => '', 'evolution_hub' => hub_block }
    )
  end

  before do
    # The cleanup concern talks to the Hub on destroy; it swallows its own
    # failures, so leaving it unconfigured keeps these examples about the guard.
    allow(EvolutionHub::Client).to receive(:new).and_raise(
      EvolutionHub::Client::ConfigurationError, 'not configured in test'
    )
  end

  describe 'DELETE /api/v1/inboxes/:id/hub_connection' do
    context 'when the connection never completed' do
      let!(:inbox) { Inbox.create!(channel: hub_channel(status: 'pending'), name: 'Pending WhatsApp') }

      before { stub_auth(granted: %w[inboxes.delete]) }

      it 'destroys the inbox and its channel' do
        delete "/api/v1/inboxes/#{inbox.id}/hub_connection", headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response['data']['id']).to eq(inbox.id)
        expect(Inbox.exists?(inbox.id)).to be(false)
        expect(Channel::Whatsapp.exists?(inbox.channel_id)).to be(false)
      end
    end

    context 'when the Hub already activated the channel' do
      let!(:inbox) { Inbox.create!(channel: hub_channel(status: 'active'), name: 'Connected WhatsApp') }

      before { stub_auth(granted: %w[inboxes.delete]) }

      it 'refuses the discard and keeps the inbox' do
        delete "/api/v1/inboxes/#{inbox.id}/hub_connection", headers: headers, as: :json

        expect(response).to have_http_status(:conflict)
        expect(json_response['error']['code']).to eq('CANNOT_DELETE_ACTIVE_RESOURCE')
        expect(Inbox.exists?(inbox.id)).to be(true)
      end
    end

    context 'when the inbox is not a Hub connection at all' do
      let!(:inbox) { Inbox.create!(channel: Channel::Api.create!, name: 'API Inbox') }

      before { stub_auth(granted: %w[inboxes.delete]) }

      it 'refuses without deleting' do
        delete "/api/v1/inboxes/#{inbox.id}/hub_connection", headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(Inbox.exists?(inbox.id)).to be(true)
      end
    end

    context 'when the user cannot delete inboxes' do
      let!(:inbox) { Inbox.create!(channel: hub_channel(status: 'pending'), name: 'Pending WhatsApp') }

      before { stub_auth(granted: %w[inboxes.read]) }

      it 'denies the request and keeps the inbox' do
        delete "/api/v1/inboxes/#{inbox.id}/hub_connection", headers: headers, as: :json

        # 401 and not 403 because fetch_inbox's Pundit denial is caught by
        # ApplicationController's around_action before Api::BaseController's
        # rescue_from can render 403 — the same pre-existing status-semantics
        # quirk asserted in inboxes_spec.rb. What matters here is the denial.
        expect(response).to have_http_status(:unauthorized)
        expect(response).not_to have_http_status(:ok)
        expect(Inbox.exists?(inbox.id)).to be(true)
      end
    end
  end
end
