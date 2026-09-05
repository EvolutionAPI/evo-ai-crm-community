# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DeleteObjectJob, type: :job do
  describe '#perform' do
    it 'deletes inbox conversations and their messages while preserving other inbox data' do
      contact = Contact.create!(name: 'Cascade Contact', email: 'cascade-contact@example.com')

      inbox = Inbox.create!(name: 'Inbox To Delete', channel: Channel::Api.create!)
      inbox_contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8))
      inbox_conversation = Conversation.create!(
        inbox: inbox,
        contact: contact,
        contact_inbox: inbox_contact_inbox
      )
      inbox_message = Message.create!(
        inbox: inbox,
        conversation: inbox_conversation,
        message_type: :incoming,
        content: 'Message in deletable inbox'
      )

      other_inbox = Inbox.create!(name: 'Inbox To Keep', channel: Channel::Api.create!)
      other_contact_inbox = ContactInbox.create!(inbox: other_inbox, contact: contact, source_id: SecureRandom.hex(8))
      other_conversation = Conversation.create!(
        inbox: other_inbox,
        contact: contact,
        contact_inbox: other_contact_inbox
      )
      other_message = Message.create!(
        inbox: other_inbox,
        conversation: other_conversation,
        message_type: :incoming,
        content: 'Message in preserved inbox'
      )

      described_class.perform_now(inbox)

      expect(Inbox.exists?(inbox.id)).to be(false)
      expect(Conversation.exists?(inbox_conversation.id)).to be(false)
      expect(Message.exists?(inbox_message.id)).to be(false)

      expect(Inbox.exists?(other_inbox.id)).to be(true)
      expect(Conversation.exists?(other_conversation.id)).to be(true)
      expect(Message.exists?(other_message.id)).to be(true)
    end

    # EVO-2186: macro_executions has a FK to conversations with no ON DELETE CASCADE
    # and no dependent: :destroy, so destroying the conversation used to raise
    # PG::ForeignKeyViolation. This is the same routine the inbox cleanup calls per
    # conversation, where the failure was swallowed and left orphan conversations.
    it 'deletes a conversation that has macro_executions' do
      contact = Contact.create!(name: 'Macro Contact', email: 'macro-contact@example.com')
      inbox = Inbox.create!(name: 'Macro Inbox', channel: Channel::Api.create!)
      contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8))
      conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      user = User.create!(email: "delete-object-#{SecureRandom.hex(4)}@example.com", name: 'Macro User')
      macro = Macro.create!(name: 'Test Macro', actions: {}, created_by: user, updated_by: user)
      macro_execution = MacroExecution.create!(macro: macro, conversation: conversation, user: user)

      described_class.perform_now(conversation)

      expect(Conversation.exists?(conversation.id)).to be(false)
      expect(MacroExecution.exists?(macro_execution.id)).to be(false)
      expect(Macro.exists?(macro.id)).to be(true)
    end
  end
end
