# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public Inbound Messages API', type: :request do
  let(:api_channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: api_channel) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:path) do
    "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}" \
      "/conversations/#{conversation.display_id}/messages"
  end

  describe 'POST create with legacy inline content' do
    it 'creates the incoming message and emits the legacy WARN with the consumer id' do
      expect(Rails.logger).to receive(:warn).with(/deprecated inline content.*consumer=legacy-consumer/).at_least(:once)

      post path, params: { content: 'hello from a contact' }, headers: { 'X-Client-ID' => 'legacy-consumer' }, as: :json

      expect(response).to have_http_status(:success)
    end
  end
end
