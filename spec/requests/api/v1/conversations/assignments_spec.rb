# frozen_string_literal: true

require 'rails_helper'

# Real request spec: boots route -> controller -> DB. Does NOT stub the
# controller path, so it would surface the previously rejected 500
# (`Current.account&.users` NoMethodError) if it ever returned.
#
# EVO-1914: assigning to an invalid/unresolvable id must return an error
# WITHOUT zeroing the existing assignee/team. A blank id is a legitimate
# unassign and stays 2xx.
RSpec.describe 'POST /api/v1/conversations/:conversation_id/assignments', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://assign.example.com') }
  let(:inbox) { Inbox.create!(name: 'Assign Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Assign Contact', email: 'assign@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:agent) { User.create!(name: 'Agent One', email: 'agent.one@example.com') }
  let(:team) { Team.create!(name: 'Support Team') }
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    # The real runtime type of Current.account is a Hash (RuntimeConfig.account =
    # get_json('account')), NOT an AR model. Forcing it here proves the controller
    # never calls `Current.account&.users` again (which raised NoMethodError -> 500).
    allow(Current).to receive(:account).and_return({ 'id' => 1, 'name' => 'Runtime Account' })
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'agent assignment (assignee_id)' do
    it 'assigns a valid agent' do
      post "/api/v1/conversations/#{conversation.id}/assignments",
           params: { assignee_id: agent.id }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(conversation.reload.assignee_id).to eq(agent.id)
      expect(json_response.dig('data', 'assignee', 'id')).to eq(agent.id)
    end

    it 'returns an error for an unresolvable id WITHOUT zeroing the existing assignee' do
      conversation.update!(assignee: agent)
      unknown_id = SecureRandom.uuid

      post "/api/v1/conversations/#{conversation.id}/assignments",
           params: { assignee_id: unknown_id }, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(json_response.dig('error', 'code')).to eq(ApiErrorCodes::RESOURCE_NOT_FOUND)
      # Existing assignee preserved — the journey "assign" must NOT silently unassign.
      expect(conversation.reload.assignee_id).to eq(agent.id)
    end

    it 'unassigns when assignee_id is blank (legitimate unassign)' do
      conversation.update!(assignee: agent)

      post "/api/v1/conversations/#{conversation.id}/assignments",
           params: { assignee_id: '' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(conversation.reload.assignee_id).to be_nil
    end
  end

  describe 'team assignment (team_id)' do
    it 'assigns a valid team' do
      post "/api/v1/conversations/#{conversation.id}/assignments",
           params: { team_id: team.id }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(conversation.reload.team_id).to eq(team.id)
      expect(json_response.dig('data', 'team', 'id')).to eq(team.id)
    end

    it 'returns an error for an unresolvable id WITHOUT zeroing the existing team' do
      conversation.update!(team: team)
      unknown_id = SecureRandom.uuid

      post "/api/v1/conversations/#{conversation.id}/assignments",
           params: { team_id: unknown_id }, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(json_response.dig('error', 'code')).to eq(ApiErrorCodes::RESOURCE_NOT_FOUND)
      expect(conversation.reload.team_id).to eq(team.id)
    end

    it 'unassigns when team_id is blank (legitimate unassign)' do
      conversation.update!(team: team)

      post "/api/v1/conversations/#{conversation.id}/assignments",
           params: { team_id: '' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(conversation.reload.team_id).to be_nil
    end
  end
end
