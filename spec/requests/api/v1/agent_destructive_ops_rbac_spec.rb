# frozen_string_literal: true

require 'rails_helper'

# Negative proof for CRM-182 — the hardened default `agent` role must be BLOCKED
# on destructive/admin endpoints while keeping attendance intact. evo-auth stops
# seeding the keys (conversations.delete, contacts.delete, pipeline_stages.delete,
# teams.create/update/delete), and these are the CRM-side gates that enforce it.
#
# Every example grants exactly AGENT_KEYS — the attendance set the agent keeps
# after CRM-182 — so a regression that re-maps any of these controllers to a key
# the agent still holds (or drops the gate entirely) turns an example red.
RSpec.describe 'Agent destructive operations RBAC (CRM-182)', type: :request do
  # The permission set the default `agent` role holds AFTER CRM-182: attendance
  # reads/writes and the kept create/update actions, but NONE of the revoked
  # destructive/admin keys.
  AGENT_KEYS = %w[
    conversations.read conversations.create conversations.update conversations.toggle_status
    contacts.read contacts.create contacts.update
    pipelines.read pipeline_items.update
    pipeline_stages.read pipeline_stages.create pipeline_stages.update
    teams.read
  ].freeze

  let(:user) { User.create!(name: 'Agent Probe', email: "agent-#{SecureRandom.hex(4)}@example.com") }

  let(:channel) { Channel::WebWidget.create!(website_url: 'https://crm182.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let(:contact) { Contact.create!(name: "Contact #{SecureRandom.hex(3)}") }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
      # Inbox visibility is not under test here; grant read_all so the probe
      # reaches the permission gate instead of being scoped out of the fixture.
      Current.evo_can_read_all_inboxes = true
    end
    # Model the real hardened agent: it holds AGENT_KEYS and nothing else.
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      AGENT_KEYS.include?(permission)
    end
  end

  after { Current.reset }

  # --- Destructive/admin endpoints the agent must NOT reach (403) ---

  describe 'DELETE /api/v1/conversations/:id (conversations.delete)' do
    it 'denies the hardened agent and leaves the conversation intact' do
      target = conversation

      delete "/api/v1/conversations/#{target.display_id}", as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Conversation.exists?(target.id)).to be(true)
    end
  end

  describe 'DELETE /api/v1/contacts/:id (contacts.delete)' do
    it 'denies the hardened agent and leaves the contact intact' do
      target = contact

      delete "/api/v1/contacts/#{target.id}", as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Contact.exists?(target.id)).to be(true)
    end
  end

  describe 'DELETE /api/v1/pipelines/:pipeline_id/pipeline_stages/:id (pipeline_stages.delete)' do
    it 'denies the hardened agent (gate fires before the pipeline is fetched)' do
      delete '/api/v1/pipelines/0/pipeline_stages/0', as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /api/v1/teams (teams.create)' do
    it 'denies the hardened agent and creates no team' do
      expect do
        post '/api/v1/teams', params: { name: "Team #{SecureRandom.hex(3)}" }, as: :json
      end.not_to change(Team, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  # --- Attendance endpoints the agent must KEEP (200) ---

  describe 'POST /api/v1/conversations/:id/toggle_status (conversations.toggle_status)' do
    it 'allows the hardened agent to close/reopen a conversation' do
      post "/api/v1/conversations/#{conversation.display_id}/toggle_status",
           params: { status: 'resolved' }, as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /api/v1/teams (teams.read)' do
    it 'allows the hardened agent to list teams for the in-chat picker' do
      get '/api/v1/teams', as: :json

      expect(response).to have_http_status(:ok)
    end
  end
end
