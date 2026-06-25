# frozen_string_literal: true

require 'rails_helper'

# EVO-1890 — re-review: prove the contact-revoke flow end-to-end WITHOUT stubbing
# the `inbox.messages.find_by(source_id:)` lookup. The earlier specs all stubbed
# that lookup, so they never proved the id carried by the `messages.delete` event
# actually matches the `source_id` stored on the original message.
RSpec.describe 'WhatsApp evolution revoke — real source_id lookup (EVO-1890)' do # rubocop:disable RSpec/DescribeClass
  let(:channel) do
    ch = Channel::Whatsapp.new(phone_number: "+55119#{rand(10_000_000..99_999_999)}", provider: 'evolution')
    ch.save!(validate: false)
    ch
  end
  let(:inbox) { Inbox.create!(name: 'WA Evolution', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@t.com") }
  let(:contact_inbox) do
    ContactInbox.create!(inbox: inbox, contact: contact, source_id: '5511999999999')
  end
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  # A realistic WhatsApp message id (the value stored as Message#source_id on inbound).
  let(:wamid) { '3EB0C767D5F1A2B3C4D5' }

  def run_delete(message_id, from_me: false)
    Whatsapp::IncomingMessageEvolutionService.new(
      inbox: inbox,
      params: { event: 'messages.delete',
                data: { id: message_id, remoteJid: '5511999999999@s.whatsapp.net', fromMe: from_me, status: 'DELETED' } }
    ).perform
  end

  it 'marks the original incoming message revoked_by_contact via the real find_by, keeping content' do
    message = conversation.messages.create!(
      inbox: inbox, message_type: :incoming, content_type: 'text',
      content: 'original message text', source_id: wamid
    )

    run_delete(wamid)

    message.reload
    expect(message.revoked_by_contact).to be(true)
    expect(message.content).to eq('original message text')
  end

  it 'does NOT mark an outgoing message (our own delete echoing back as fromMe)' do
    message = conversation.messages.create!(
      inbox: inbox, message_type: :outgoing, content_type: 'text',
      content: 'agent reply', source_id: wamid
    )

    run_delete(wamid, from_me: true)

    expect(message.reload.revoked_by_contact).to be_falsey
  end

  it 'ingests via the real upsert then revokes by the same key id (proves inbound source_id == delete id)' do
    Whatsapp::IncomingMessageEvolutionService.new(
      inbox: inbox,
      params: { event: 'messages.upsert',
                data: { key: { id: wamid, remoteJid: '5511999999999@s.whatsapp.net', fromMe: false },
                        pushName: 'Contact', message: { conversation: 'original via upsert' } } }
    ).perform

    created = inbox.messages.find_by(source_id: wamid)
    expect(created).to be_present
    expect(created).to be_incoming

    run_delete(wamid)

    expect(created.reload.revoked_by_contact).to be(true)
    expect(created.content).to eq('original via upsert')
  end

  it 'is a no-op when no message matches the revoked id (no crash, nothing marked)' do
    other = conversation.messages.create!(
      inbox: inbox, message_type: :incoming, content_type: 'text',
      content: 'unrelated', source_id: 'SOME_OTHER_ID'
    )

    expect { run_delete(wamid) }.not_to raise_error
    expect(other.reload.revoked_by_contact).to be_falsey
  end
end
