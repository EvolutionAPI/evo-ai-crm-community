# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::DeleteMessageOnProviderJob do
  it 'propagates the delete and records revoke_propagated for an outgoing message' do
    channel = double('channel', delete_message: true)
    inbox = double('inbox', channel: channel)
    conversation = double('conversation', inbox: inbox)
    message = double('message', outgoing?: true, conversation: conversation, content_attributes: {})

    allow(Message).to receive(:find_by).with(id: 1).and_return(message)
    expect(channel).to receive(:delete_message).with(message).and_return(true)
    expect(message).to receive(:update!).with(content_attributes: { revoke_propagated: true })

    described_class.perform_now(1)
  end

  it 'does nothing for a non-outgoing message' do
    message = double('message', outgoing?: false)
    allow(Message).to receive(:find_by).with(id: 2).and_return(message)

    expect { described_class.perform_now(2) }.not_to raise_error
  end

  it 'does nothing when the message no longer exists' do
    allow(Message).to receive(:find_by).with(id: 3).and_return(nil)

    expect { described_class.perform_now(3) }.not_to raise_error
  end
end
