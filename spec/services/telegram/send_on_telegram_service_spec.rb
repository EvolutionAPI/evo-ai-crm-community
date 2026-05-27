# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Telegram::SendOnTelegramService' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Telegram::SendOnTelegramService do
  let(:channel) { instance_double(Channel::Telegram) }
  let(:message) { instance_double(Message, failed?: false, update!: true) }
  let(:service) { described_class.new(message: message) }
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  before do
    allow(service).to receive_messages(channel: channel, inbox: instance_double(Inbox, channel: channel))
  end

  describe '#perform_reply' do
    context 'when send returns a Telegram message_id' do
      it 'sets source_id and emits delivered via StatusUpdateService' do
        allow(channel).to receive(:send_message_on_telegram).with(message).and_return('tg-123')

        expect(message).to receive(:update!).with(source_id: 'tg-123')
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)

        service.send(:perform_reply)
      end
    end

    context 'when send returns nil' do
      it 'does not emit delivered' do
        allow(channel).to receive(:send_message_on_telegram).with(message).and_return(nil)

        expect(Messages::StatusUpdateService).not_to receive(:new)
        service.send(:perform_reply)
      end
    end

    context 'when the message is already failed (process_error fired first)' do
      it 'does not emit delivered' do
        allow(channel).to receive(:send_message_on_telegram).with(message).and_return('tg-123')
        allow(message).to receive(:failed?).and_return(true)

        expect(Messages::StatusUpdateService).not_to receive(:new)
        service.send(:perform_reply)
      end
    end
  end
end
