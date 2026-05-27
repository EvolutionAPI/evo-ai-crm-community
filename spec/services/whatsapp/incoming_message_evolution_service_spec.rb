# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::IncomingMessageEvolutionService' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::IncomingMessageEvolutionService do
  describe 'messages.update activity refresh' do
    let(:message) do
      instance_double(
        Message,
        created_at: Time.zone.parse('2026-02-12 10:00:00'),
        status: 'sent'
      )
    end

    let(:service) { described_class.new(inbox: inbox, params: params) }
    let(:inbox) { instance_double(Inbox, channel: instance_double(Channel::Whatsapp)) }
    let(:params) do
      {
        event: 'messages.update',
        data: {
          messageId: 'msg-1',
          status: 'DELIVERED',
          fromMe: false
        }
      }
    end

    before do
      allow(service).to receive(:find_message_by_source_id).and_return(true)
      service.instance_variable_set(:@message, message)
      service.instance_variable_set(:@raw_message, params[:data])
    end

    it 'refreshes conversation activity when status updates' do
      allow(service).to receive(:status_mapper).and_return('delivered')
      allow(service).to receive(:incoming?).and_return(false)
      allow(message).to receive(:update!)
      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      allow(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)

      expect(message).to receive(:refresh_conversation_activity!).with(message.created_at, use_current_time: false)

      service.send(:update_status)
    end

    it 'refreshes conversation activity when message content is edited' do
      allow(service).to receive(:extract_edited_content).and_return('updated')
      allow(message).to receive(:content_attributes).and_return({})
      allow(message).to receive(:content).and_return('old')
      allow(message).to receive(:update!)

      expect(message).to receive(:refresh_conversation_activity!).with(message.created_at, use_current_time: false)

      service.send(:handle_edited_content)
    end
  end
end
