# frozen_string_literal: true

require 'rails_helper'

# EVO-1231 [6.2]: global (channel-less) message-template CRUD exposed via the
# existing per-inbox endpoints with the `?global=true` toggle.
RSpec.describe 'Api::V1::Inboxes message templates (global mode)', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let(:channel) { Channel::Api.create!(hmac_mandatory: false) }
  let(:inbox) { Inbox.create!(channel: channel, name: "Inbox #{SecureRandom.hex(3)}") }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'POST /api/v1/inboxes/:id/message_templates?global=true' do
    it 'creates a channel-less template (AC1)' do
      post "/api/v1/inboxes/#{inbox.id}/message_templates?global=true",
           params: { message_template: { name: "g-#{SecureRandom.hex(4)}", content: 'Hello' } },
           headers: headers, as: :json

      expect(response).to have_http_status(:created)
      created = MessageTemplate.find(json_response['data']['id'])
      expect(created.channel_id).to be_nil
      expect(created.channel_type).to be_nil
    end

    it 'rejects a WhatsApp Cloud template without a channel (AC5)' do
      post "/api/v1/inboxes/#{inbox.id}/message_templates?global=true",
           params: { message_template: { name: "wac-#{SecureRandom.hex(4)}", content: 'Hello', provider: 'whatsapp_cloud' } },
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'GET /api/v1/inboxes/:id/message_templates?global=true (AC2)' do
    it 'lists global templates' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Hi')

      get "/api/v1/inboxes/#{inbox.id}/message_templates?global=true", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |t| t['name'] }).to include(template.name)
    end
  end

  describe 'PUT /api/v1/inboxes/:id/message_templates/:template_id?global=true (AC3)' do
    it 'updates a global template' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Old')

      put "/api/v1/inboxes/#{inbox.id}/message_templates/#{template.id}?global=true",
          params: { message_template: { content: 'New' } },
          headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(template.reload.content).to eq('New')
    end
  end

  describe 'DELETE /api/v1/inboxes/:id/message_templates/:template_id?global=true (AC4)' do
    it 'deletes a global template' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Bye')

      delete "/api/v1/inboxes/#{inbox.id}/message_templates/#{template.id}?global=true",
             headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(MessageTemplate.exists?(template.id)).to be(false)
    end
  end

  describe 'global scoping (excludes channel-bound and inactive templates)' do
    def whatsapp_channel
      ch = Channel::Whatsapp.new(provider: 'evolution', phone_number: "+1555#{SecureRandom.hex(3)}")
      ch.save!(validate: false)
      ch
    end

    it 'GET does not leak channel-bound templates' do
      global = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'global')
      bound = MessageTemplate.create!(name: "b-#{SecureRandom.hex(4)}", content: 'bound', channel: whatsapp_channel)

      get "/api/v1/inboxes/#{inbox.id}/message_templates?global=true", headers: headers, as: :json

      names = json_response['data'].map { |t| t['name'] }
      expect(names).to include(global.name)
      expect(names).not_to include(bound.name)
    end

    it 'GET does not return inactive global templates' do
      inactive = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'hidden', active: false)

      get "/api/v1/inboxes/#{inbox.id}/message_templates?global=true", headers: headers, as: :json

      expect(json_response['data'].map { |t| t['name'] }).not_to include(inactive.name)
    end

    it 'PUT cannot reach a channel-bound template' do
      bound = MessageTemplate.create!(name: "b-#{SecureRandom.hex(4)}", content: 'bound', channel: whatsapp_channel)

      put "/api/v1/inboxes/#{inbox.id}/message_templates/#{bound.id}?global=true",
          params: { message_template: { content: 'hacked' } },
          headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(bound.reload.content).to eq('bound')
    end

    it 'DELETE cannot reach a channel-bound template' do
      bound = MessageTemplate.create!(name: "b-#{SecureRandom.hex(4)}", content: 'bound', channel: whatsapp_channel)

      delete "/api/v1/inboxes/#{inbox.id}/message_templates/#{bound.id}?global=true",
             headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(MessageTemplate.exists?(bound.id)).to be(true)
    end
  end

  describe 'permission enforcement (AC6)' do
    let(:forbidden_user) { User.create!(name: 'No Perm', email: "noperm-#{SecureRandom.hex(4)}@example.com") }

    before do
      # Authenticate as a user (not a service token) so the require_permissions
      # gate evaluates the remote permission, which we deny.
      allow_any_instance_of(Api::V1::InboxesController)
        .to receive(:authenticate_request!) { Current.user = forbidden_user }
      allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(false)
    end

    it 'returns 403 when the user lacks inboxes.message_templates' do
      get "/api/v1/inboxes/#{inbox.id}/message_templates?global=true", as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
