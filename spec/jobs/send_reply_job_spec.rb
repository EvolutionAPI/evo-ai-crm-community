# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SendReplyJob do
  # CRM-358: a provider that raises (e.g. Evolution Go on HTTP error) must
  # still land in the status funnel — the raw `update(status: :failed)` the
  # rescue used before never published :message_status_changed.
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
end
