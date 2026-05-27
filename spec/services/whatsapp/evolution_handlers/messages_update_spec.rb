# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionHandlers::MessagesUpdate' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::EvolutionHandlers::MessagesUpdate do
  let(:host_class) do
    Class.new do
      include Whatsapp::EvolutionHandlers::MessagesUpdate

      attr_accessor :raw_message_id
    end
  end

  let(:message) do
    instance_double(
      Message,
      status: 'sent',
      conversation: nil,
      created_at: Time.zone.now,
      refresh_conversation_activity!: true
    )
  end

  subject(:host) { host_class.new }

  before do
    host.instance_variable_set(:@message, message)
    allow(host).to receive(:incoming?).and_return(false)
  end

  describe '#update_status' do
    context 'when mapped status is delivered' do
      it 'delegates to Messages::StatusUpdateService' do
        host.instance_variable_set(:@raw_message, { status: 'DELIVERY_ACK' })
        status_service = instance_double(Messages::StatusUpdateService, perform: true)
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)

        host.send(:update_status)
      end
    end

    context 'when mapped status is read' do
      it 'delegates with read' do
        host.instance_variable_set(:@raw_message, { status: 'READ' })
        status_service = instance_double(Messages::StatusUpdateService, perform: true)
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'read').and_return(status_service)

        host.send(:update_status)
      end
    end

    context 'when mapped status is failed' do
      it 'delegates with failed and nil external_error (parity with current behavior)' do
        host.instance_variable_set(:@raw_message, { status: 'ERROR' })
        status_service = instance_double(Messages::StatusUpdateService, perform: true)
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed').and_return(status_service)

        host.send(:update_status)
      end
    end

    context 'when the service rejects an invalid transition' do
      it 'does not refresh conversation activity' do
        host.instance_variable_set(:@raw_message, { status: 'DELIVERY_ACK' })
        status_service = instance_double(Messages::StatusUpdateService, perform: false)
        allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

        expect(message).not_to receive(:refresh_conversation_activity!)
        host.send(:update_status)
      end
    end

    context 'when the raw status is unknown' do
      it 'does not invoke the service' do
        host.instance_variable_set(:@raw_message, { status: 'BOGUS' })
        expect(Messages::StatusUpdateService).not_to receive(:new)

        host.send(:update_status)
      end
    end
  end

  # AC3 / L-6: exercise the REAL funnel (no mock of Messages::StatusUpdateService)
  # to prove failed→delivered cannot un-fail a message through the Evolution API
  # channel. Catches future regressions where the funnel's failed-final guard
  # is removed but channel specs (which mock the service) stay green.
  describe '#update_status — funnel e2e (no service mock)' do
    it 'AC3 e2e: real funnel rejects failed→delivered' do
      failed_message = instance_double(
        Message, status: 'failed', failed?: true, read?: false, delivered?: false,
                 content_attributes: {}
      )
      host.instance_variable_set(:@message, failed_message)
      host.instance_variable_set(:@raw_message, { status: 'DELIVERY_ACK' })
      allow(host).to receive(:refresh_conversation_activity)
      allow(Message).to receive(:statuses).and_return('sent' => 0, 'delivered' => 1, 'read' => 2, 'failed' => 3)

      expect(failed_message).not_to receive(:update!)
      host.send(:update_status)
    end
  end
end
