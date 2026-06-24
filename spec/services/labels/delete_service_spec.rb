# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Labels::DeleteService do
  let(:title) { 'vip' }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  before { Label.create!(title: title) }

  it 'removes the label from tagged conversations and contacts' do
    conversation.update!(label_list: [title])
    contact.update!(label_list: [title])

    described_class.new(label_title: title).perform

    expect(conversation.reload.label_list).not_to include(title)
    expect(contact.reload.label_list).not_to include(title)
    expect(Conversation.tagged_with(title)).to be_empty
    expect(Contact.tagged_with(title)).to be_empty
  end

  it 'dirty-tracks the conversation removal so CONVERSATION_UPDATED is dispatched (EVO-1863 review)' do
    user = User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com")
    Current.user = user
    conversation.update!(label_list: [title])

    dispatched = []
    allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, *_args|
      dispatched << event_name
    end

    described_class.new(label_title: title).perform

    expect(dispatched).to include(Conversation::CONVERSATION_UPDATED)
  ensure
    Current.reset
  end

  it 'is a no-op when the label is not in use' do
    expect { described_class.new(label_title: title).perform }.not_to raise_error
  end
end
