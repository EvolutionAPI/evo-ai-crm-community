# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MailboxHelper do
  let(:mailbox) { Imap::ImapMailbox.new }
  let(:messages) { instance_double(ActiveRecord::Associations::CollectionProxy, find_by: nil) }
  let(:contact) { instance_double(Contact) }
  let(:conversation) { instance_double(Conversation, messages: messages, contact: contact, inbox_id: SecureRandom.uuid) }

  it 'sanitizes both the deduplication key and the complete incoming message before persistence' do
    mailbox.conversation = conversation
    mailbox.processed_mail = MailPresenter.new(Mail.new)
    allow(mailbox.processed_mail).to receive_messages(
      message_id: "message\u0000@example.com",
      serialized_data: { subject: "Sub\u0000ject", text: { full: "Bo\u0000dy" } },
      cc: ["cc\u0000@example.com"], bcc: []
    )
    allow(mailbox).to receive(:mail_content).and_return("Bo\u0000dy")

    expect(messages).to receive(:find_by).with(source_id: 'message@example.com').and_return(nil)
    expect(messages).to receive(:create!).with(
      sender: contact, content: 'Body', inbox_id: conversation.inbox_id, message_type: 'incoming',
      content_type: 'incoming_email', source_id: 'message@example.com',
      content_attributes: { email: { subject: 'Subject', text: { full: 'Body' } }, cc_email: ['cc@example.com'], bcc_email: [] }
    )

    mailbox.send(:create_message)
  end

  it 'does not reintroduce NUL bytes while rewriting inline attachment content' do
    mailbox.processed_mail = MailPresenter.new(Mail.new)
    allow(mailbox.processed_mail).to receive_messages(
      message_id: 'message@example.com',
      serialized_data: { html_content: { full: "<p>Hi\u0000</p>" }, text_content: { reply: "Hi\u0000" } }
    )
    attributes = { email: { html_content: {}, text_content: {} } }
    mailbox.instance_variable_set(:@message, instance_double(Message, content_attributes: attributes))

    mailbox.send(:process_inline_attachments, [])

    expect(attributes[:email]).to eq(html_content: { full: '<p>Hi</p>' }, text_content: { full: 'Hi' })
  end

  it 'sanitizes filenames interpolated into a plain-text inline image' do
    mailbox.processed_mail = MailPresenter.new(Mail.new)
    allow(mailbox.processed_mail).to receive_messages(
      message_id: 'message@example.com',
      serialized_data: { html_content: { full: '' }, text_content: { reply: 'An image' } }
    )
    attributes = { email: { html_content: {}, text_content: {} } }
    mailbox.instance_variable_set(:@message, instance_double(Message, content_attributes: attributes))
    allow(mailbox).to receive(:inline_image_url).and_return('https://crm.example.com/image.png')
    part = Mail::Part.new
    allow(part).to receive(:filename).and_return("image\u0000.png")
    attachment = { original: part, blob: nil }

    mailbox.send(:process_inline_attachments, [attachment])

    expect(attributes[:email][:text_content][:full]).to include('image.png')
    expect(attributes[:email][:text_content][:full]).not_to include("\u0000")
  end
end
