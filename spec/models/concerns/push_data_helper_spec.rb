# frozen_string_literal: true

require 'rails_helper'

# Covers the wiring of each egress to its side of `include_labels_data:`. The webhook
# body is a customer contract, so the assertion sits on `webhook_data`, not the presenter.
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

    # Built before the "is any webhook configured?" check, so a leak here is
    # paid by every message, not only by accounts with a webhook.
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
