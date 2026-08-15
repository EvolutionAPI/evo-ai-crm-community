# frozen_string_literal: true

require 'rails_helper'

# CRM-155: the presenter spec proves `push_data(include_labels_data:)` behaves.
# This one proves each egress is wired to the right side of that flag — the
# webhook body is a customer-facing contract, so the assertion has to sit on
# `webhook_data` itself and not on the presenter it delegates to.
RSpec.describe PushDataHelper do
  let!(:label) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }

  let(:contact) { Contact.create!(name: 'PD', email: "pd-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://pd.example.com') }
  let(:inbox) { Inbox.create!(name: 'PD Inbox', channel: channel) }
  let(:contact_inbox) do
    ContactInbox.create!(inbox: inbox, contact: contact, source_id: "pd-#{SecureRandom.hex(4)}")
  end
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  before { conversation.update!(label_list: ['urgente']) }

  describe '#webhook_data' do
    it 'does not carry labels_data' do
      expect(conversation.webhook_data).not_to have_key(:labels_data)
    end

    it 'keeps labels as the list of titles it has always been' do
      expect(conversation.webhook_data[:labels].to_a).to eq(['urgente'])
    end

    # Message#webhook_data embeds this hash and is built before the "is any
    # webhook configured?" check, so a leak here is paid by every message.
    it 'stays out of the conversation embedded in Message#webhook_data' do
      message = Message.create!(
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'oi'
      )

      expect(message.webhook_data[:conversation]).not_to have_key(:labels_data)
    end
  end

  describe '#push_event_data' do
    it 'carries the full label for the realtime consumers' do
      expect(conversation.push_event_data[:labels_data]).to eq(
        [{ id: label.id, title: 'urgente', color: '#ff0000' }]
      )
    end

    it 'keeps labels as titles alongside it' do
      expect(conversation.push_event_data[:labels].to_a).to eq(['urgente'])
    end
  end
end
