# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionGoHandlers::ReceiptHandler' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::EvolutionGoHandlers::ReceiptHandler do
  let(:host_class) do
    Class.new do
      include Whatsapp::EvolutionGoHandlers::ReceiptHandler

      attr_writer :inbox
    end
  end

  subject(:host) { host_class.new }

  describe '#process_single_receipt' do
    let(:message) { instance_double(Message, source_id: 'go.1', status: 'sent') }

    before do
      allow(host).to receive(:find_message_by_source_id_for_receipt).and_return(message)
    end

    it 'delegates to Messages::StatusUpdateService for an updatable transition' do
      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)

      host.send(:process_single_receipt, 'go.1', 'delivered', {})
    end

    it 'skips when can_update_message_status? returns false' do
      allow(message).to receive(:status).and_return('read')
      expect(Messages::StatusUpdateService).not_to receive(:new)

      host.send(:process_single_receipt, 'go.1', 'delivered', {})
    end
  end

  describe Whatsapp::EvolutionGoHandlers::BulkStatusPublisher do
    it 'publishes :message_status_changed with the canonical payload' do
      collected = []
      listener = Class.new do
        define_method(:message_status_changed) { |data| collected << data }
      end.new
      message = instance_double(Message, id: 11)

      publisher = described_class.new
      publisher.subscribe(listener)
      publisher.emit(message, 'sent', 'delivered')

      expect(collected.size).to eq(1)
      expect(collected.first[:data]).to include(
        message: message,
        previous_status: 'sent',
        status: 'delivered',
        external_error: nil
      )
    end
  end

  # AC10 / L-6: pre-bulk filter (`can_update_message_status?`) must keep
  # parity with the canonical funnel rules so that update_all does not
  # write terminal-state regressions. Tested at the predicate level since
  # this is the only barrier in the bulk path.
  describe '#can_update_message_status? — funnel parity' do
    let(:msg) { ->(status) { instance_double(Message, status: status) } }

    it 'rejects same-status (delivered → delivered) — F-1 parity' do
      expect(host.send(:can_update_message_status?, msg.call('delivered'), 'delivered')).to be(false)
    end

    it 'rejects transitions out of read (read final)' do
      %w[sent delivered failed].each do |target|
        expect(host.send(:can_update_message_status?, msg.call('read'), target)).to be(false)
      end
    end

    it 'rejects transitions out of failed (failed final)' do
      %w[sent delivered read].each do |target|
        expect(host.send(:can_update_message_status?, msg.call('failed'), target)).to be(false)
      end
    end

    it 'rejects delivered → sent regression' do
      expect(host.send(:can_update_message_status?, msg.call('delivered'), 'sent')).to be(false)
    end

    it 'accepts sent → delivered/read/failed' do
      %w[delivered read failed].each do |target|
        expect(host.send(:can_update_message_status?, msg.call('sent'), target)).to be(true)
      end
    end

    it 'accepts delivered → read' do
      expect(host.send(:can_update_message_status?, msg.call('delivered'), 'read')).to be(true)
    end
  end
end
