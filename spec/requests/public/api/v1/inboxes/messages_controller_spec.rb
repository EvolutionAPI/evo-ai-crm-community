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

  describe 'POST create with inline content' do
    # Inbound messages always carry content and have no template alternative, so
    # the deprecated-inline-content WARN must NOT fire here — it would spam the
    # signal meant to identify legacy OUTBOUND consumers (EVO-1720 [6.11]).
    it 'creates the incoming message without the legacy deprecated-content WARN' do
      allow(Rails.logger).to receive(:warn)

      expect do
        post path, params: { content: 'hello from a contact' },
                   headers: { 'X-Client-ID' => 'legacy-consumer' }, as: :json
      end.to change(conversation.messages, :count).by(1)

      expect(response).to have_http_status(:success)
      created = conversation.messages.last
      expect(created.message_type).to eq('incoming')
      expect(created.content).to eq('hello from a contact')
      expect(Rails.logger).not_to have_received(:warn).with(/deprecated inline content/)
    end
  end
end
