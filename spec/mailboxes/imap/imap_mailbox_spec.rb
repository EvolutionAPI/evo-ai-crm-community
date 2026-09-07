# frozen_string_literal: true

require 'rails_helper'

# Routing fixtures bypass unrelated channel provisioning and message callbacks.
# rubocop:disable Rails/SkipsModelValidations
RSpec.describe Imap::ImapMailbox do
  let(:mailbox) { described_class.new }
  let(:inbox) do
    id = Inbox.insert_all!([{ channel_id: SecureRandom.uuid, channel_type: 'Channel::Email', name: 'Support' }]).rows.first.first
    Inbox.find(id)
  end
  let(:conversation) do
    id = Conversation.insert_all!([{ inbox_id: inbox.id, display_id: 1 }]).rows.first.first
    Conversation.find(id)
  end

  before do
    mailbox.inbox = inbox
  end

  def resolve_reference(reference)
    mail = Mail.new
    mail.references = reference
    mailbox.instance_variable_set(:@inbound_mail, mail)
    mailbox.send(:find_conversation_by_reference_ids)
  end

  it 'threads a reference emitted by the reply mailer when the source message is missing' do
    reference = "conversation/#{conversation.uuid}/messages/#{SecureRandom.uuid}@support.example.com"
    expect(resolve_reference(reference)).to eq(conversation)
  end

  it 'accepts the conversation-only reference emitted by the reply mailer' do
    expect(resolve_reference("conversation/#{conversation.uuid}@support.example.com")).to eq(conversation)
  end

  it 'does not match a conversation belonging to another inbox' do
    reference = "conversation/#{conversation.uuid}/messages/#{SecureRandom.uuid}@support.example.com"
    other_id = Inbox.insert_all!([{ channel_id: SecureRandom.uuid, channel_type: 'Channel::Email', name: 'Other' }]).rows.first.first
    mailbox.inbox = Inbox.find(other_id)

    expect(resolve_reference(reference)).to be_nil
  end

  it 'prefers the matching message over a fallback conversation reference' do
    other_id = Conversation.insert_all!([{ inbox_id: inbox.id, display_id: 2 }]).rows.first.first
    Message.insert_all!([{ inbox_id: inbox.id, conversation_id: other_id, message_type: 1, source_id: 'sent@example.com' }])

    expect(resolve_reference(["conversation/#{conversation.uuid}@support.example.com", 'sent@example.com']).id).to eq(other_id)
  end

  it 'ignores malformed conversation identifiers without querying an invalid UUID' do
    expect(resolve_reference('conversation/not-a-uuid/messages/1@example.com')).to be_nil
  end

  it 'strips NUL bytes before looking up the In-Reply-To header' do
    mailbox.processed_mail = instance_double(MailPresenter, in_reply_to: "message\u0000@example.com")
    expect(mailbox.send(:in_reply_to)).to eq('message@example.com')
  end
end

# rubocop:enable Rails/SkipsModelValidations
