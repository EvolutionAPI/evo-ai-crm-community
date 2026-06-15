# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplates::Template::OutOfOffice do
  # Plain ActiveRecord setup (this repo has no model factories beyond roles;
  # mirrors spec/requests/.../messages_controller_spec.rb).
  let(:api_channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: api_channel) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:service) { described_class.new(conversation: conversation) }

  # Global template with a required variable the auto-reply never supplies, so
  # rendering raises and TemplateContent falls back to the inline column. The
  # token must appear in content or the explicit var is stripped on save (F1).
  let(:raising_template) do
    MessageTemplate.create!(
      name: "ooo-required-#{SecureRandom.hex(4)}",
      content: 'Away, ref {{order_id}}',
      variables: [{ 'name' => 'order_id', 'required' => true }],
      channel: nil
    )
  end

  it 'builds a template whose render actually raises (guards against a vacuous test)' do
    expect { raising_template.render_with_variables('first_name' => 'Ada') }
      .to raise_error(ArgumentError)
  end

  describe '#perform' do
    context 'when the template render fails AND the inline fallback is blank (AC5)' do
      before do
        inbox.update!(
          out_of_office_message: '',
          out_of_office_message_template_id: raising_template.id
        )
      end

      it 'creates no message (no blank out-of-office is delivered)' do
        expect { service.perform }.not_to change(conversation.messages, :count)
      end
    end

    context 'when the template render fails but the inline fallback is present' do
      before do
        inbox.update!(
          out_of_office_message: 'We are away',
          out_of_office_message_template_id: raising_template.id
        )
      end

      it 'falls back to the inline content and creates one template message' do
        expect { service.perform }.to change(conversation.messages, :count).by(1)

        message = conversation.messages.last
        expect(message.message_type).to eq('template')
        expect(message.content_type).to eq('text')
        expect(message.content).to eq('We are away')
      end
    end

    context 'when there is no template id but inline content is present' do
      before do
        inbox.update!(
          out_of_office_message: 'Out of office',
          out_of_office_message_template_id: nil
        )
      end

      it 'creates one template message from the inline content' do
        expect { service.perform }.to change(conversation.messages, :count).by(1)
        expect(conversation.messages.last.content).to eq('Out of office')
      end
    end
  end
end
