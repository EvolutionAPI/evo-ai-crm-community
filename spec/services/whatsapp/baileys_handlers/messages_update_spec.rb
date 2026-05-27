# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::BaileysHandlers::MessagesUpdate' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::BaileysHandlers::MessagesUpdate do
  let(:host_class) do
    Class.new do
      include Whatsapp::BaileysHandlers::MessagesUpdate
    end
  end

  subject(:host) { host_class.new }
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  before { allow(host).to receive(:incoming?).and_return(false) }

  describe '#update_status' do
    # Baileys delegates ALL status transitions to
    # Messages::StatusUpdateService — same-status, read-final, failed-final,
    # and delivered→sent are now barred inside the funnel. The service is
    # always invoked but returns false for invalid transitions.
    it 'delegates delivered→sent to the funnel (service rejects)' do
      message = instance_double(Message, status: 'delivered', delivered?: true, read?: false)
      host.instance_variable_set(:@message, message)
      host.instance_variable_set(:@raw_message, { update: { status: 2 } })

      rejecting = instance_double(Messages::StatusUpdateService, perform: false)
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'sent').and_return(rejecting)
      host.send(:update_status)
    end

    it 'delegates transitions from read to the funnel (service rejects)' do
      message = instance_double(Message, status: 'read', read?: true, delivered?: false)
      host.instance_variable_set(:@message, message)
      host.instance_variable_set(:@raw_message, { update: { status: 0 } }) # ERROR → failed

      rejecting = instance_double(Messages::StatusUpdateService, perform: false)
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed').and_return(rejecting)
      host.send(:update_status)
    end

    it 'delegates sent→delivered to the service' do
      message = instance_double(Message, status: 'sent', delivered?: false, read?: false)
      host.instance_variable_set(:@message, message)
      host.instance_variable_set(:@raw_message, { update: { status: 3 } })

      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)
      host.send(:update_status)
    end

    it 'delegates read to the service for an incoming message' do
      message = instance_double(Message, status: 'delivered', delivered?: false, read?: false)
      host.instance_variable_set(:@message, message)
      host.instance_variable_set(:@raw_message, { update: { status: 4 } })
      allow(host).to receive_messages(incoming?: true, update_last_seen_at: nil)

      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'read').and_return(status_service)
      host.send(:update_status)
    end
  end

  # AC9 / L-6: exercise the REAL funnel (no mock of Messages::StatusUpdateService)
  # to prove the funnel's same-status guard works end-to-end through the Baileys
  # channel. Without this, a future regression in valid_status_transition? would
  # not be caught by channel specs that mock the service.
  describe '#update_status — funnel e2e (no service mock)' do
    it 'AC4 e2e: real funnel barres delivered→sent regression' do
      message = instance_double(
        Message, status: 'delivered', delivered?: true, read?: false, failed?: false,
                 content_attributes: {}
      )
      host.instance_variable_set(:@message, message)
      host.instance_variable_set(:@raw_message, { update: { status: 2 } }) # SERVER_ACK → sent
      allow(Message).to receive(:statuses).and_return('sent' => 0, 'delivered' => 1, 'read' => 2, 'failed' => 3)

      expect(message).not_to receive(:update!)
      host.send(:update_status)
    end
  end
end
