require 'rails_helper'

RSpec.describe 'POST /api/v1/conversations/:conversation_id/toggle_typing_status', type: :request do
  include ActiveJob::TestHelper

  let!(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let!(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let!(:contact) { Contact.create!(name: 'Test Contact', email: 'test@example.com') }
  let!(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let!(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let!(:agent_bot) { AgentBot.create!(name: 'Test Bot', outgoing_url: 'http://example.com') }

  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token, 'ACCEPT' => 'application/json' } }

  let!(:webhook) do
    Webhook.create!(
      inbox: inbox,
      url: 'https://crm.example.com/webhook',
      webhook_type: 'account_type',
      subscriptions: %w[conversation_typing_on conversation_typing_off]
    )
  end

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    AgentBotInbox.create!(agent_bot: agent_bot, inbox: inbox)

    # We must allow other events (like conversation.created) to pass through if triggered
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_call_original
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
  end

  describe 'toggle_typing_status flow' do
    it 'simulates the full flow of typing_on event down to the WebhookJob' do
      # Expect the synchronous dispatcher to be called
      expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
        'conversation.typing_on',
        any_args
      ).and_call_original

      # Perform all jobs to ensure EventDispatcherJob and WebhookJob are executed
      perform_enqueued_jobs do
        expect do
          post toggle_typing_status_api_v1_conversation_path(conversation.display_id),
               params: { typing_status: 'on' },
               headers: headers
        end.not_to raise_error
      end

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body)['message']).to eq('Typing status updated successfully')

      # Verify that the WebhookJob was enqueued with the correct contract
      webhook_jobs = performed_jobs.select { |j| j[:job] == WebhookJob }
      expect(webhook_jobs).not_to be_empty

      # Parse the arguments passed to WebhookJob
      job_args = webhook_jobs.first[:args]
      expect(job_args[0]).to eq('https://crm.example.com/webhook')

      payload = job_args[1].with_indifferent_access
      expect(payload[:event]).to eq('conversation_typing_on')
      expect(payload[:conversation]).to be_present

      # Assert the bot data is present in the payload (the fallback logic)
      expect(payload[:user]).to be_present
      expect(payload[:user][:id]).to eq(agent_bot.id)
      expect(payload[:user][:type]).to eq('agent_bot')
      expect(payload[:user][:name]).to eq('Test Bot')

      expect(payload[:is_private]).to eq(false)
    end

    it 'simulates the full flow of typing_off event down to the WebhookJob' do
      expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
        'conversation.typing_off',
        any_args
      ).and_call_original

      perform_enqueued_jobs do
        expect do
          post toggle_typing_status_api_v1_conversation_path(conversation.display_id),
               params: { typing_status: 'off', is_private: true },
               headers: headers
        end.not_to raise_error
      end

      expect(response).to have_http_status(:success)

      webhook_jobs = performed_jobs.select { |j| j[:job] == WebhookJob }
      expect(webhook_jobs).not_to be_empty

      job_args = webhook_jobs.first[:args]
      payload = job_args[1].with_indifferent_access
      expect(payload[:event]).to eq('conversation_typing_off')

      # Assert the bot data is present
      expect(payload[:user]).to be_present
      expect(payload[:user][:id]).to eq(agent_bot.id)

      expect(payload[:is_private].to_s).to eq('true')
    end
  end
end
