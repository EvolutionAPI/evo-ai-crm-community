# frozen_string_literal: true

require 'rails_helper'

# EVO-1716: dedicated, account-scoped message-template CRUD at the flat
# /api/v1/message_templates endpoint. Global (channel-less) when no inbox is
# given; channel-bound when `inbox_id` is supplied. Meta sync stays inbox-scoped.
RSpec.describe 'Api::V1::MessageTemplates', type: :request do
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

  def whatsapp_channel(provider = 'evolution')
    ch = Channel::Whatsapp.new(provider: provider, phone_number: "+1555#{SecureRandom.hex(3)}")
    ch.save!(validate: false)
    ch
  end

  describe 'POST /api/v1/message_templates (global)' do
    it 'creates a channel-less template (AC1)' do
      post '/api/v1/message_templates',
           params: { message_template: { name: "g-#{SecureRandom.hex(4)}", content: 'Hello' } },
           headers: headers, as: :json

      expect(response).to have_http_status(:created)
      created = MessageTemplate.find(json_response['data']['id'])
      expect(created.channel_id).to be_nil
      expect(created.channel_type).to be_nil
    end

    it 'rejects a WhatsApp Cloud template without a channel (AC1)' do
      post '/api/v1/message_templates',
           params: { message_template: { name: "wac-#{SecureRandom.hex(4)}", content: 'Hi', provider: 'whatsapp_cloud' } },
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'returns 422 on a duplicate global name (AC5)' do
      name = "dup-#{SecureRandom.hex(4)}"
      MessageTemplate.create!(name: name, content: 'first')

      post '/api/v1/message_templates',
           params: { message_template: { name: name, content: 'second' } },
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'GET /api/v1/message_templates (global, AC1)' do
    it 'lists global templates' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Hi')

      get '/api/v1/message_templates', headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |t| t['name'] }).to include(template.name)
    end

    it 'does not leak channel-bound templates' do
      global = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'global')
      bound = MessageTemplate.create!(name: "b-#{SecureRandom.hex(4)}", content: 'bound', channel: whatsapp_channel)

      get '/api/v1/message_templates', headers: headers, as: :json

      names = json_response['data'].map { |t| t['name'] }
      expect(names).to include(global.name)
      expect(names).not_to include(bound.name)
    end

    it 'does not return inactive global templates' do
      inactive = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'hidden', active: false)

      get '/api/v1/message_templates', headers: headers, as: :json

      expect(json_response['data'].map { |t| t['name'] }).not_to include(inactive.name)
    end
  end

  describe 'GET /api/v1/message_templates/:id (AC1)' do
    it 'returns a single template' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Hi')

      get "/api/v1/message_templates/#{template.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']['id']).to eq(template.id)
    end

    it 'returns 404 for an unknown id' do
      get "/api/v1/message_templates/#{SecureRandom.uuid}", headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PUT /api/v1/message_templates/:id (global, AC1)' do
    it 'updates a global template' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Old')

      put "/api/v1/message_templates/#{template.id}",
          params: { message_template: { content: 'New' } },
          headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(template.reload.content).to eq('New')
    end

    it 'cannot reach a channel-bound template' do
      bound = MessageTemplate.create!(name: "b-#{SecureRandom.hex(4)}", content: 'bound', channel: whatsapp_channel)

      put "/api/v1/message_templates/#{bound.id}",
          params: { message_template: { content: 'hacked' } },
          headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(bound.reload.content).to eq('bound')
    end
  end

  describe 'DELETE /api/v1/message_templates/:id (global, AC1)' do
    it 'deletes a global template' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Bye')

      delete "/api/v1/message_templates/#{template.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(MessageTemplate.exists?(template.id)).to be(false)
    end

    it 'cannot reach a channel-bound template' do
      bound = MessageTemplate.create!(name: "b-#{SecureRandom.hex(4)}", content: 'bound', channel: whatsapp_channel)

      delete "/api/v1/message_templates/#{bound.id}", headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(MessageTemplate.exists?(bound.id)).to be(true)
    end
  end

  describe 'channel-bound CRUD via inbox_id (AC2 / AC3)' do
    it 'creates a template bound to the inbox channel' do
      post '/api/v1/message_templates',
           params: { inbox_id: inbox.id, message_template: { name: "b-#{SecureRandom.hex(4)}", content: 'bound' } },
           headers: headers, as: :json

      expect(response).to have_http_status(:created)
      created = MessageTemplate.find(json_response['data']['id'])
      expect(created.channel_id).to eq(channel.id)
    end

    it 'lists only that channel templates when filtered by inbox_id' do
      global = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'global')
      bound = MessageTemplate.create!(name: "b-#{SecureRandom.hex(4)}", content: 'bound', channel: channel)

      get "/api/v1/message_templates?inbox_id=#{inbox.id}", headers: headers, as: :json

      names = json_response['data'].map { |t| t['name'] }
      expect(names).to include(bound.name)
      expect(names).not_to include(global.name)
    end
  end

  # Real-user path: unlike the service-token specs above (which bypass BOTH the
  # require_permissions remote gate and Pundit), these authenticate a user so the
  # `message_templates.*` resource contract is actually exercised. In the community
  # build User#has_permission? is always true, so check_user_permission is the only
  # real gate — stub it per key to lock the contract.
  describe 'authorization with a real user (AC4)' do
    let(:agent_user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@example.com") }

    before do
      allow_any_instance_of(Api::V1::MessageTemplatesController)
        .to receive(:authenticate_request!) { Current.user = agent_user }
    end

    it 'allows create when granted message_templates.create (201)' do
      allow_any_instance_of(EvoAuthService)
        .to receive(:check_user_permission).with(anything, 'message_templates.create').and_return(true)

      post '/api/v1/message_templates',
           params: { message_template: { name: "g-#{SecureRandom.hex(4)}", content: 'Hello' } },
           as: :json

      expect(response).to have_http_status(:created)
    end

    it 'allows index when granted message_templates.read (200)' do
      allow_any_instance_of(EvoAuthService)
        .to receive(:check_user_permission).with(anything, 'message_templates.read').and_return(true)

      get '/api/v1/message_templates', as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'returns 403 when the user lacks the permission' do
      allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(false)

      get '/api/v1/message_templates', as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'cutover: legacy inbox-nested CRUD routes are gone (AC7)' do
    it 'no longer routes the old global GET/POST (404)' do
      get "/api/v1/inboxes/#{inbox.id}/message_templates", headers: headers, as: :json
      expect(response).to have_http_status(:not_found)

      post "/api/v1/inboxes/#{inbox.id}/message_templates",
           params: { message_template: { name: 'x', content: 'y' } }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  # EVO-1232 [6.3] — STAYS inbox-scoped (NOT moved by EVO-1716). Regression guard. (AC6)
  describe 'POST /api/v1/inboxes/:id/message_templates/:template_id/sync_with_whatsapp_cloud' do
    it 'enqueues the sync job and returns 202 for a WhatsApp Cloud template' do
      template = MessageTemplate.create!(name: "wac-#{SecureRandom.hex(4)}", content: 'Hi',
                                         channel: whatsapp_channel('whatsapp_cloud'))

      expect(SyncMessageTemplateWithWhatsappCloudJob).to receive(:perform_later).with(an_instance_of(MessageTemplate))

      post "/api/v1/inboxes/#{inbox.id}/message_templates/#{template.id}/sync_with_whatsapp_cloud",
           headers: headers, as: :json

      expect(response).to have_http_status(:accepted)
      expect(json_response['data']['template']['id']).to eq(template.id)
    end

    it 'returns 422 and does not enqueue for a channel-less template' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Hi')

      expect(SyncMessageTemplateWithWhatsappCloudJob).not_to receive(:perform_later)

      post "/api/v1/inboxes/#{inbox.id}/message_templates/#{template.id}/sync_with_whatsapp_cloud",
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'returns 422 and does not enqueue for a non-WhatsApp-Cloud channel' do
      template = MessageTemplate.create!(name: "ev-#{SecureRandom.hex(4)}", content: 'Hi',
                                         channel: whatsapp_channel('evolution'))

      expect(SyncMessageTemplateWithWhatsappCloudJob).not_to receive(:perform_later)

      post "/api/v1/inboxes/#{inbox.id}/message_templates/#{template.id}/sync_with_whatsapp_cloud",
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'returns 404 for an unknown template id' do
      expect(SyncMessageTemplateWithWhatsappCloudJob).not_to receive(:perform_later)

      post "/api/v1/inboxes/#{inbox.id}/message_templates/#{SecureRandom.uuid}/sync_with_whatsapp_cloud",
           headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 403 without the inboxes.message_templates permission' do
      template = MessageTemplate.create!(name: "wac-#{SecureRandom.hex(4)}", content: 'Hi',
                                         channel: whatsapp_channel('whatsapp_cloud'))
      forbidden_user = User.create!(name: 'No Perm', email: "noperm-#{SecureRandom.hex(4)}@example.com")
      allow_any_instance_of(Api::V1::InboxesController)
        .to receive(:authenticate_request!) { Current.user = forbidden_user }
      allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(false)

      post "/api/v1/inboxes/#{inbox.id}/message_templates/#{template.id}/sync_with_whatsapp_cloud", as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
