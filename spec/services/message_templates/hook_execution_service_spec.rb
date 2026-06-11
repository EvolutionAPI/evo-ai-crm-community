# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplates::HookExecutionService do
  let(:web_widget) { create(:channel_widget) }
  let(:inbox) { create(:inbox, channel: web_widget) }
  let(:contact_without_email) { create(:contact, email: nil) }
  let(:contact_with_email) { create(:contact, email: 'test@example.com') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact_without_email, inbox: inbox) }

  describe '#perform' do
    context 'when email collect is enabled and pre-chat form is disabled' do
      before do
        inbox.update!(enable_email_collect: true)
        web_widget.update!(pre_chat_form_enabled: false)
      end

      it 'sends email collect messages when contact has no email' do
        conversation = create(:conversation,
                              inbox: inbox,
                              contact: contact_without_email,
                              contact_inbox: contact_inbox)

        message = create(:message,
                         conversation: conversation,
                         inbox: inbox,
                         message_type: :incoming,
                         sender: contact_without_email)

        service = described_class.new(message: message)
        service.perform

        email_collect_messages = conversation.messages.where(content_type: 'input_email')
        expect(email_collect_messages.count).to eq(1)
      end

      it 'does not send email collect when contact already has email' do
        ci = create(:contact_inbox, contact: contact_with_email, inbox: inbox)
        conversation = create(:conversation,
                              inbox: inbox,
                              contact: contact_with_email,
                              contact_inbox: ci)

        message = create(:message,
                         conversation: conversation,
                         inbox: inbox,
                         message_type: :incoming,
                         sender: contact_with_email)

        service = described_class.new(message: message)
        service.perform

        email_collect_messages = conversation.messages.where(content_type: 'input_email')
        expect(email_collect_messages.count).to eq(0)
      end

      it 'sends email collect even when messages association cache is stale' do
        conversation = create(:conversation,
                              inbox: inbox,
                              contact: contact_without_email,
                              contact_inbox: contact_inbox)

        message = create(:message,
                         conversation: conversation,
                         inbox: inbox,
                         message_type: :incoming,
                         sender: contact_without_email)

        conversation.messages.to_a

        service = described_class.new(message: message)
        service.perform

        email_collect_messages = conversation.messages.reload.where(content_type: 'input_email')
        expect(email_collect_messages.count).to eq(1)
      end

      it 'does not send duplicate email collect when already sent' do
        conversation = create(:conversation,
                              inbox: inbox,
                              contact: contact_without_email,
                              contact_inbox: contact_inbox)

        create(:message,
               conversation: conversation,
               inbox: inbox,
               message_type: :template,
               content_type: 'input_email')

        message = create(:message,
                         conversation: conversation,
                         inbox: inbox,
                         message_type: :incoming,
                         sender: contact_without_email)

        service = described_class.new(message: message)
        service.perform

        email_collect_messages = conversation.messages.where(content_type: 'input_email')
        expect(email_collect_messages.count).to eq(1)
      end
    end

    context 'when email collect is disabled' do
      before do
        inbox.update!(enable_email_collect: false)
      end

      it 'does not send email collect messages' do
        conversation = create(:conversation,
                              inbox: inbox,
                              contact: contact_without_email,
                              contact_inbox: contact_inbox)

        message = create(:message,
                         conversation: conversation,
                         inbox: inbox,
                         message_type: :incoming,
                         sender: contact_without_email)

        service = described_class.new(message: message)
        service.perform

        email_collect_messages = conversation.messages.where(content_type: 'input_email')
        expect(email_collect_messages.count).to eq(0)
      end
    end

    context 'when conversation has no incoming messages' do
      it 'returns early without triggering templates' do
        conversation = create(:conversation,
                              inbox: inbox,
                              contact: contact_without_email,
                              contact_inbox: contact_inbox)

        message = create(:message,
                         conversation: conversation,
                         inbox: inbox,
                         message_type: :outgoing)

        service = described_class.new(message: message)

        expect(MessageTemplates::Template::EmailCollect).not_to receive(:new)
        service.perform
      end
    end
  end

  describe 'greeting referencing a MessageTemplate (EVO-1235)' do
    let(:api_channel) { Channel::Api.create! }
    let(:greeting_template) { MessageTemplate.create!(name: 'greet', content: 'Hi {{first_name}}', channel: nil) }
    let(:api_inbox) do
      Inbox.create!(name: 'API', channel: api_channel, greeting_enabled: true,
                    greeting_message_template_id: greeting_template.id)
    end
    let(:greet_contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
    let(:greet_contact_inbox) { ContactInbox.create!(inbox: api_inbox, contact: greet_contact, source_id: SecureRandom.hex(4)) }
    let(:greet_conversation) { Conversation.create!(inbox: api_inbox, contact: greet_contact, contact_inbox: greet_contact_inbox) }

    def trigger_first_incoming
      message = Message.create!(conversation: greet_conversation, inbox: api_inbox,
                                message_type: :incoming, sender: greet_contact, content: 'hello')
      described_class.new(message: message).perform
    end

    it 'sends the rendered template as the greeting even when the string column is blank' do
      trigger_first_incoming
      greeting = greet_conversation.messages.where(message_type: :template).last
      expect(greeting.content).to eq('Hi Ada')
    end

    it 'falls back to the inline string column when no template is referenced' do
      api_inbox.update!(greeting_message_template_id: nil, greeting_message: 'Plain hello')
      trigger_first_incoming
      greeting = greet_conversation.messages.where(message_type: :template).last
      expect(greeting.content).to eq('Plain hello')
    end
  end
end
