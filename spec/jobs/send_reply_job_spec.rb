# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SendReplyJob do
  # A provider that raises must still land in the status funnel: the raw
  # `update(status: :failed)` the rescue used before published no Wisper event.
  let(:channel) { instance_double(Channel::Whatsapp) }
  let(:inbox) { instance_double(Inbox, channel: channel) }
  let(:conversation) { instance_double(Conversation, inbox: inbox) }
  let(:message) { instance_double(Message, id: 42, conversation: conversation) }

  before do
    allow(channel).to receive(:class).and_return(Channel::Whatsapp)
    allow(Message).to receive(:find).with(42).and_return(message)
    allow(Whatsapp::SendOnWhatsappService).to receive(:new)
      .and_raise('[Evolution Go] HTTP 500: boom')
  end

  it 'routes a raising provider through Messages::StatusUpdateService' do
    status_service = instance_double(Messages::StatusUpdateService)
    expect(Messages::StatusUpdateService).to receive(:new)
      .with(message, 'failed', '[Evolution Go] HTTP 500: boom')
      .and_return(status_service)
    expect(status_service).to receive(:perform)

    described_class.perform_now(42)
  end

  # The marking itself must never raise out of the job's rescue — a Sidekiq
  # retry here would RE-SEND a message that may already be delivered.
  it 'falls back to a raw column write when the funnel raises' do
    status_service = instance_double(Messages::StatusUpdateService)
    allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)
    allow(status_service).to receive(:perform)
      .and_raise(ActiveRecord::RecordInvalid.new(Message.new))
    allow(message).to receive(:content_attributes).and_return({})

    expect(message).to receive(:update_columns).with(
      status: :failed,
      content_attributes: { 'external_error' => '[Evolution Go] HTTP 500: boom' }
    )

    expect { described_class.perform_now(42) }.not_to raise_error
  end

  # The double above proves the call shape, not that the write lands. The enum
  # symbol and the JSON store coder have to survive update_columns for real.
  describe 'the last-resort write against a persisted message' do
    let(:widget_channel) { Channel::WebWidget.create!(website_url: 'https://send-reply.example.com') }
    let(:real_inbox) { Inbox.create!(name: 'SendReply Inbox', channel: widget_channel) }
    let(:contact) { Contact.create!(name: 'SR', email: "sr-#{SecureRandom.hex(4)}@test.com") }
    let(:contact_inbox) do
      ContactInbox.create!(inbox: real_inbox, contact: contact, source_id: "sr-#{SecureRandom.hex(4)}")
    end
    let(:real_conversation) do
      Conversation.create!(inbox: real_inbox, contact: contact, contact_inbox: contact_inbox)
    end
    let(:real_message) do
      Message.create!(inbox: real_inbox, conversation: real_conversation, message_type: :outgoing, content: 'hi')
    end

    it 'persists failed and the reason without raising' do
      expect(real_message.status).to eq('sent')

      expect do
        described_class.new.send(:mark_failed_through_funnel, real_message, 'boom')
      end.not_to raise_error

      real_message.reload
      expect(real_message.status).to eq('failed')
      expect(real_message.external_error).to eq('boom')
    end

    it 'still persists failed when the funnel raises' do
      allow(Messages::StatusUpdateService).to receive(:new).and_raise(ActiveRecord::RecordInvalid.new(Message.new))

      expect do
        described_class.new.send(:mark_failed_through_funnel, real_message, 'boom')
      end.not_to raise_error

      real_message.reload
      expect(real_message.status).to eq('failed')
      expect(real_message.external_error).to eq('boom')
    end
  end
end
