# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# A present-but-unknown agent_bot id used to answer 200 without binding anything.
# It must be a 404; an absent/blank id keeps the unlink semantics.
RSpec.describe 'Api::V1::Inboxes set_agent_bot', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let!(:user) { User.create!(name: 'Bot Binder', email: "bot-binder-#{SecureRandom.hex(4)}@example.com") }
  let!(:inbox) { Inbox.create!(channel: Channel::Api.create!, name: 'Canal Bot') }
  let!(:bot) { AgentBot.create!(name: 'Bot Real', outgoing_url: 'https://example.test/bot') }

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

  def stub_auth
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { user: { id: user.id, email: user.email, role: { id: 1, key: 'administrator', name: 'administrator' } } }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return(
        status: 200,
        body: { success: true, data: { has_permission: true } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  before do
    stub_auth
    Current.user = user
  end

  describe 'POST /api/v1/inboxes/:id/set_agent_bot' do
    it 'returns 404 for a nonexistent agent_bot id and creates no binding' do
      expect do
        post "/api/v1/inboxes/#{inbox.id}/set_agent_bot",
             params: { agent_bot: SecureRandom.uuid }, headers: headers, as: :json
      end.not_to change(AgentBotInbox, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig('error', 'code')).to eq('RESOURCE_NOT_FOUND')
    end

    it 'returns 404 for a nonexistent id WITHOUT unlinking an existing binding' do
      AgentBotInbox.create!(inbox: inbox, agent_bot: bot, status: :active)

      post "/api/v1/inboxes/#{inbox.id}/set_agent_bot",
           params: { agent_bot: SecureRandom.uuid }, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(inbox.reload.agent_bot).to eq(bot)
    end

    it 'binds a real agent_bot with 200' do
      post "/api/v1/inboxes/#{inbox.id}/set_agent_bot",
           params: { agent_bot: bot.id }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(inbox.reload.agent_bot).to eq(bot)
    end

    it 'also binds via the agent_bot_id param (server-side callers — EVO-1900)' do
      post "/api/v1/inboxes/#{inbox.id}/set_agent_bot",
           params: { agent_bot_id: bot.id }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(inbox.reload.agent_bot).to eq(bot)
    end

    it 'returns 404 for a malformed (non-UUID) id' do
      post "/api/v1/inboxes/#{inbox.id}/set_agent_bot",
           params: { agent_bot: 'nao-e-uuid' }, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(inbox.reload.agent_bot).to be_nil
    end

    it 'answers 403 before the 404 when the caller lacks inboxes.update' do
      stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
        .to_return(
          status: 200,
          body: { success: true, data: { has_permission: false } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post "/api/v1/inboxes/#{inbox.id}/set_agent_bot",
           params: { agent_bot: SecureRandom.uuid }, headers: headers, as: :json

      # fetch_agent_bot is declared after require_permissions precisely so an
      # unknown id cannot tell an unauthorized caller whether the bot exists.
      expect(response).to have_http_status(:forbidden)
    end

    it 'unbinds with 200 when agent_bot is blank and a binding exists' do
      AgentBotInbox.create!(inbox: inbox, agent_bot: bot, status: :active)

      post "/api/v1/inboxes/#{inbox.id}/set_agent_bot",
           params: { agent_bot: '' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(inbox.reload.agent_bot).to be_nil
    end
  end
end
