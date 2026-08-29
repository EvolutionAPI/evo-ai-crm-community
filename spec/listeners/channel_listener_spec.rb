require 'rails_helper'

RSpec.describe ChannelListener do
  let(:listener) { described_class.instance }
  let(:channel) { instance_double('Channel::Whatsapp') }
  let(:inbox) { instance_double('Inbox', channel: channel) }
  let(:conversation) { instance_double('Conversation', inbox: inbox) }

  describe '#conversation_typing_on' do
    let(:event_name) { 'conversation.typing_on' }

    before do
      # Allow the channel to respond to toggle_typing_status
      allow(channel).to receive(:respond_to?).with(:toggle_typing_status).and_return(true)
      allow(channel).to receive(:toggle_typing_status)
    end

    context 'when is_private is truthy' do
      it 'does not toggle typing status on the channel when is_private is true' do
        event = Events::Base.new(event_name, Time.zone.now, { conversation: conversation, is_private: true })
        listener.conversation_typing_on(event)
        expect(channel).not_to have_received(:toggle_typing_status)
      end

      it 'does not toggle typing status on the channel when is_private is "true"' do
        event = Events::Base.new(event_name, Time.zone.now, { conversation: conversation, is_private: 'true' })
        listener.conversation_typing_on(event)
        expect(channel).not_to have_received(:toggle_typing_status)
      end

      it 'does not toggle typing status on the channel when is_private is "1"' do
        event = Events::Base.new(event_name, Time.zone.now, { conversation: conversation, is_private: '1' })
        listener.conversation_typing_on(event)
        expect(channel).not_to have_received(:toggle_typing_status)
      end
    end

    context 'when is_private is falsy' do
      it 'toggles typing status on the channel when is_private is false' do
        event = Events::Base.new(event_name, Time.zone.now, { conversation: conversation, is_private: false })
        listener.conversation_typing_on(event)
        expect(channel).to have_received(:toggle_typing_status).with(event_name, conversation: conversation)
      end

      it 'toggles typing status on the channel when is_private is "false"' do
        event = Events::Base.new(event_name, Time.zone.now, { conversation: conversation, is_private: 'false' })
        listener.conversation_typing_on(event)
        expect(channel).to have_received(:toggle_typing_status).with(event_name, conversation: conversation)
      end

      it 'toggles typing status on the channel when is_private is "0"' do
        event = Events::Base.new(event_name, Time.zone.now, { conversation: conversation, is_private: '0' })
        listener.conversation_typing_on(event)
        expect(channel).to have_received(:toggle_typing_status).with(event_name, conversation: conversation)
      end

      it 'toggles typing status on the channel when is_private is nil' do
        event = Events::Base.new(event_name, Time.zone.now, { conversation: conversation, is_private: nil })
        listener.conversation_typing_on(event)
        expect(channel).to have_received(:toggle_typing_status).with(event_name, conversation: conversation)
      end
    end


    context 'when event.data has string keys (e.g. from ActiveJob serialization)' do
      it 'safely extracts is_private and conversation and toggles typing status' do
        event = Events::Base.new(event_name, Time.zone.now, { 'conversation' => conversation, 'is_private' => false })
        listener.conversation_typing_on(event)
        expect(channel).to have_received(:toggle_typing_status).with(event_name, conversation: conversation)
      end
    end

    context 'when channel does not support toggle_typing_status' do
      before do
        allow(channel).to receive(:respond_to?).with(:toggle_typing_status).and_return(false)
      end

      it 'does not raise an error and aborts' do
        event = Events::Base.new(event_name, Time.zone.now, { conversation: conversation, is_private: false })
        expect { listener.conversation_typing_on(event) }.not_to raise_error
      end
    end
  end
end
