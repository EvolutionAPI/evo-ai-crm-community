# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionGoHandlers::MessagesUpdate' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::EvolutionGoHandlers::MessagesUpdate do
  let(:host_class) do
    Class.new do
      include Whatsapp::EvolutionGoHandlers::MessagesUpdate
    end
  end

  let(:message) { instance_double(Message, status: 'sent') }
  subject(:host) { host_class.new }

  describe '#update_message_status' do
    let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

    it 'delegates DELIVERY_ACK as delivered' do
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)
      host.send(:update_message_status, message, { status: 'DELIVERY_ACK' }, 'msg-1')
    end

    it 'delegates READ as read' do
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'read').and_return(status_service)
      host.send(:update_message_status, message, { status: 'READ' }, 'msg-1')
    end

    it 'delegates ERROR as failed' do
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed').and_return(status_service)
      host.send(:update_message_status, message, { status: 'ERROR' }, 'msg-1')
    end

    it 'does not invoke the service when the raw status is unknown' do
      expect(Messages::StatusUpdateService).not_to receive(:new)
      host.send(:update_message_status, message, { status: 'BOGUS' }, 'msg-1')
    end

    # After EVO-1239: the local same-status guard was removed; the funnel
    # handles this universally. Service is now invoked but returns false.
    it 'delegates to the funnel for same-status updates (funnel rejects)' do
      delivered_message = instance_double(Message, status: 'delivered')
      rejecting = instance_double(Messages::StatusUpdateService, perform: false)
      expect(Messages::StatusUpdateService).to receive(:new).with(delivered_message, 'delivered').and_return(rejecting)
      host.send(:update_message_status, delivered_message, { status: 'DELIVERY_ACK' }, 'msg-1')
    end
  end
end
