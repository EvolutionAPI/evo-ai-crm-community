# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public Outbound Messages API', type: :request do
  let(:api_channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: api_channel) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:path) do
    "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}" \
      "/conversations/#{conversation.display_id}/outbound_messages"
  end

  def json_response
    response.parsed_body
  end

  describe 'POST create' do
    context 'with a valid message_template_id' do
      let(:template) { MessageTemplate.create!(name: 'welcome', content: 'Hi {{first_name}}', channel: nil) }

      it 'creates an outgoing message rendered from the template' do
        post path, params: { message_template_id: template.id, processed_params: { first_name: 'Ada' } }, as: :json

        expect(response).to have_http_status(:created)
        expect(json_response['content']).to eq('Hi Ada')
        expect(json_response['message_type']).to eq('outgoing')
      end
    end

    context 'with inline content (deprecated)' do
      it 'creates the message and emits a WARN identifying the consumer' do
        expect(Rails.logger).to receive(:warn).with(/deprecated inline content.*consumer=/).at_least(:once)

        post path, params: { content: 'plain inline body' }, headers: { 'X-Client-ID' => 'legacy-consumer' }, as: :json

        expect(response).to have_http_status(:created)
        expect(json_response['content']).to eq('plain inline body')
      end
    end

    context 'with an unknown message_template_id' do
      it 'responds 422 and creates no message' do
        expect do
          post path, params: { message_template_id: SecureRandom.uuid }, as: :json
        end.not_to(change { conversation.messages.count })

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context 'with a valid id but a missing required variable' do
      let(:required_var_template) do
        MessageTemplate.create!(
          name: 'needs_name',
          content: 'Hi {{first_name}}',
          channel: nil,
          variables: [{ 'name' => 'first_name', 'type' => 'text', 'required' => true }]
        )
      end

      it 'responds 422 and creates no message' do
        expect do
          post path, params: { message_template_id: required_var_template.id, processed_params: {} }, as: :json
        end.not_to(change { conversation.messages.count })

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end
end
