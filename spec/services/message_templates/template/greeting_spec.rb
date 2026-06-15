# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplates::Template::Greeting do
  # Plain ActiveRecord setup (this repo has no model factories beyond roles;
  # mirrors spec/requests/.../messages_controller_spec.rb).
  let(:api_channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: api_channel) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:service) { described_class.new(conversation: conversation) }

  # A global template with a required variable the auto-reply never supplies
  # (the auto-reply only passes first_name/name/email), so rendering raises.
  # NOTE: the token MUST appear in `content` or extract_variables_from_content
  # strips the explicit variable on save (see EVO-1720 spec, F1).
  let(:raising_template) do
    MessageTemplate.create!(
      name: "greeting-required-#{SecureRandom.hex(4)}",
      content: 'Hi {{order_id}}',
      variables: [{ 'name' => 'order_id', 'required' => true }],
      channel: nil
    )
  end

  it 'builds a template whose render actually raises (guards against a vacuous test)' do
    expect { raising_template.render_with_variables('first_name' => 'Ada') }
      .to raise_error(ArgumentError)
  end

  describe '#perform' do
    context 'when the template render fails AND the inline fallback is blank (AC3)' do
      before do
        inbox.update!(
          greeting_enabled: true,
          greeting_message: '',
          greeting_message_template_id: raising_template.id
        )
      end

      it 'creates no message (no blank greeting is delivered)' do
        expect { service.perform }.not_to change(conversation.messages, :count)
      end
    end

    context 'when the template render fails but the inline fallback is present (AC4a)' do
      before do
        inbox.update!(
          greeting_enabled: true,
          greeting_message: 'Welcome!',
          greeting_message_template_id: raising_template.id
        )
      end

      it 'falls back to the inline content and creates one template message' do
        expect { service.perform }.to change(conversation.messages, :count).by(1)

        message = conversation.messages.last
        expect(message.message_type).to eq('template')
        expect(message.content_type).to eq('text')
        expect(message.content).to eq('Welcome!')
      end
    end

    context 'when there is no template id but inline content is present (AC4b)' do
      before do
        inbox.update!(
          greeting_enabled: true,
          greeting_message: 'Hello there',
          greeting_message_template_id: nil
        )
      end

      it 'creates one template message from the inline content' do
        expect { service.perform }.to change(conversation.messages, :count).by(1)
        expect(conversation.messages.last.content).to eq('Hello there')
      end
    end

    context 'when a blank greeting was previously skipped (AC6 — no false "already greeted")' do
      before do
        inbox.update!(
          greeting_enabled: true,
          greeting_message: '',
          greeting_message_template_id: raising_template.id
        )
      end

      it 'leaves zero template messages so a later valid greeting can still fire' do
        service.perform
        # The blank skip created nothing — the messages.template count that
        # HookExecutionService#first_message_from_contact? checks stays at zero.
        expect(conversation.messages.template.count).to eq(0)

        inbox.update!(greeting_message: 'Welcome!')
        expect { described_class.new(conversation: conversation).perform }
          .to change(conversation.messages.template, :count).by(1)
      end
    end
  end
end
