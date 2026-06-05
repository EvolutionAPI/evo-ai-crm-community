# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/conversations/:id/email_team', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://emailteam.example.com') }
  let(:inbox) { Inbox.create!(name: 'Spec Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Spec Contact', email: 'spec@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:team) { Team.create!(name: "Team #{SecureRandom.hex(3)}") }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }
  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  it 'enqueues a team notification mailer for each team' do
    mailer = double(deliver_later: true)
    allow(TeamNotifications::AutomationNotificationMailer)
      .to receive(:conversation_creation).and_return(mailer)

    post "/api/v1/conversations/#{conversation.id}/email_team",
         params: { team_ids: [team.id], message: 'Heads up' },
         headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(TeamNotifications::AutomationNotificationMailer)
      .to have_received(:conversation_creation).with(conversation, team, 'Heads up')
    expect(mailer).to have_received(:deliver_later)
  end

  it 'returns 400 when team_ids or message is missing' do
    post "/api/v1/conversations/#{conversation.id}/email_team",
         params: { message: 'x' }, headers: headers, as: :json

    expect(response).to have_http_status(:bad_request)
  end
end
