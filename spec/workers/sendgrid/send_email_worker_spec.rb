# frozen_string_literal: true

require 'rails_helper'

# EVO-1251 (story 9.4): the worker dispatches the SendGrid send and must survive
# a provider error (the client already logged + flagged the message failed).
RSpec.describe Sendgrid::SendEmailWorker do
  let(:channel) { instance_double(Channel::Sendgrid) }
  let(:inbox) { instance_double(Inbox, channel: channel) }
  let(:conversation) { instance_double(Conversation, inbox: inbox) }
  let(:message) { instance_double(Message, email_notifiable_message?: true, conversation: conversation) }
  let(:client) { instance_double(Sendgrid::Client) }

  before do
    allow(Message).to receive(:find_by).with(id: 1).and_return(message)
    allow(channel).to receive(:is_a?).with(Channel::Sendgrid).and_return(true)
    allow(Sendgrid::Client).to receive(:new).with(channel).and_return(client)
  end

  it 'delivers the message through Sendgrid::Client' do
    expect(client).to receive(:deliver).with(message: message)

    described_class.new.perform(1)
  end

  it 'swallows a Sendgrid::ApiError without crashing the worker' do
    allow(client).to receive(:deliver).and_raise(Sendgrid::ApiError.new('boom', 400, nil))

    expect { described_class.new.perform(1) }.not_to raise_error
  end

  it 'does nothing when the message no longer exists' do
    allow(Message).to receive(:find_by).with(id: 99).and_return(nil)

    expect(Sendgrid::Client).not_to receive(:new)
    described_class.new.perform(99)
  end

  it 'does not dispatch when the channel is not SendGrid' do
    allow(channel).to receive(:is_a?).with(Channel::Sendgrid).and_return(false)

    expect(client).not_to receive(:deliver)
    described_class.new.perform(1)
  end
end
