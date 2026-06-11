# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::MessageBuilder do
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def global_template
    MessageTemplate.create!(name: 'welcome', content: 'Hi {{first_name}}', channel: nil)
  end

  describe '#perform with a template' do
    it 'resolves a GLOBAL template by id and renders the content' do
      template = global_template

      params = {
        message_type: 'outgoing',
        template_params: { 'id' => template.id, 'processed_params' => { 'first_name' => 'Ada' } }
      }
      message = described_class.new(nil, conversation, params).perform

      expect(message.content).to eq('Hi Ada')
    end

    it 'persists the resolved template id in additional_attributes.template_params' do
      template = global_template

      params = {
        message_type: 'outgoing',
        template_params: { 'id' => template.id, 'processed_params' => { 'first_name' => 'Ada' } }
      }
      message = described_class.new(nil, conversation, params).perform

      expect(message.additional_attributes['template_params']['id']).to eq(template.id)
    end

    it 'resolves by id even when no name is provided (id is canonical)' do
      template = global_template

      params = {
        message_type: 'outgoing',
        template_params: { 'id' => template.id, 'processed_params' => { 'first_name' => 'Grace' } }
      }
      message = described_class.new(nil, conversation, params).perform

      expect(message.content).to eq('Hi Grace')
    end

    it 'still resolves by name when no id is provided and records the resolved id' do
      template = global_template

      params = {
        message_type: 'outgoing',
        template_params: { 'name' => 'welcome', 'processed_params' => { 'first_name' => 'Edsger' } }
      }
      message = described_class.new(nil, conversation, params).perform

      expect(message.content).to eq('Hi Edsger')
      expect(message.additional_attributes['template_params']['id']).to eq(template.id)
    end
  end
end
