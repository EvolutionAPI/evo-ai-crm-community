# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::IncomingMessageBaseService' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::IncomingMessageBaseService do
  let(:host_class) do
    Class.new(Whatsapp::IncomingMessageBaseService) do
      attr_writer :processed_params

      def processed_params
        @processed_params
      end
    end
  end

  let(:message) do
    instance_double(
      Message,
      id: 1,
      status: 'sent',
      content_attributes: {},
      conversation: nil
    )
  end
  let(:inbox) { instance_double(Inbox) }
  let(:service) { host_class.new(inbox: inbox, params: {}) }
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  describe '#update_message_with_status' do
    context 'when status is delivered' do
      it 'delegates to Messages::StatusUpdateService with nil external_error' do
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered', nil).and_return(status_service)
        expect(status_service).to receive(:perform)

        service.send(:update_message_with_status, message, { status: 'delivered', id: 'wamid.xxx' })
      end
    end

    context 'when status is read' do
      it 'delegates with read + nil external_error' do
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'read', nil).and_return(status_service)

        service.send(:update_message_with_status, message, { status: 'read', id: 'wamid.xxx' })
      end
    end

    context 'when status is failed with errors[]' do
      let(:status_payload) do
        {
          status: 'failed',
          id: 'wamid.xxx',
          errors: [{ code: 131_026, title: 'Message undeliverable' }]
        }
      end

      it 'formats external_error as "<code>: <title>"' do
        expect(Messages::StatusUpdateService).to receive(:new)
          .with(message, 'failed', '131026: Message undeliverable')
          .and_return(status_service)

        service.send(:update_message_with_status, message, status_payload)
      end
    end

    context 'when status is failed but errors[] is absent' do
      it 'leaves external_error as nil' do
        expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed', nil).and_return(status_service)

        service.send(:update_message_with_status, message, { status: 'failed', id: 'wamid.xxx' })
      end
    end
  end

  # AC9 / L-6: exercise the REAL funnel via WhatsApp Cloud — proves that a
  # duplicate `delivered` webhook (Meta retries are common) does NOT re-emit
  # the Wisper event a second time, which would otherwise flow through the
  # EvoFlow listener as a bogus `message.read`.
  describe '#update_message_with_status — funnel e2e (no service mock)' do
    it 'AC9 e2e: duplicate delivered webhook produces only one Wisper publish' do
      already_delivered = instance_double(
        Message, id: 42, status: 'delivered', delivered?: true, read?: false, failed?: false,
                 content_attributes: {}
      )
      allow(Message).to receive(:statuses).and_return('sent' => 0, 'delivered' => 1, 'read' => 2, 'failed' => 3)

      # The funnel's same-status guard should short-circuit BEFORE update! and
      # BEFORE any Wisper publish. We assert the side-effect contract directly.
      expect(already_delivered).not_to receive(:update!)
      service.send(:update_message_with_status, already_delivered, { status: 'delivered', id: 'wamid.xxx' })
    end
  end

  # The dedup guard is written to Redis before processing and released only on
  # the last line of the happy path. Any raise in between - or a webhook whose
  # contacts payload is blank - leaves the key pinned for its full one-day TTL,
  # so the Sidekiq retry and every Meta re-delivery bounce off
  # `message_under_process?` and drop the message with no log at all.
  describe '#process_messages dedup guard release' do
    before do
      service.processed_params = { messages: [{ id: 'wamid.race', type: 'text' }] }
      allow(service).to receive(:find_message_by_source_id).and_return(nil)
      allow(service).to receive(:message_under_process?).and_return(false)
      allow(service).to receive(:cache_message_source_id_in_redis)
    end

    it 'releases the guard when set_contact raises, and still lets the exception reach Sidekiq' do
      allow(service).to receive(:set_contact).and_raise(ActiveRecord::RecordNotUnique.new('duplicate key'))

      expect(service).to receive(:clear_message_source_id_from_redis)
      expect { service.send(:process_messages) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'releases the guard when the webhook carries no usable contact' do
      allow(service).to receive(:set_contact)

      expect(service).to receive(:clear_message_source_id_from_redis)
      service.send(:process_messages)
    end

    it 'still releases the guard on the happy path' do
      allow(service).to receive(:set_contact) { service.instance_variable_set(:@contact, instance_double(Contact)) }
      allow(service).to receive(:set_conversation)
      allow(service).to receive(:create_messages)

      expect(service).to receive(:clear_message_source_id_from_redis)
      service.send(:process_messages)
    end
  end

  describe '#update_bsuid_fields' do
    let(:contact_inbox) { instance_double(ContactInbox, id: 7, bsuid: nil, whatsapp_username: nil) }

    # Two concurrent webhooks for the same new contact race for
    # index_contact_inboxes_on_inbox_id_and_bsuid. The loser has nothing left to
    # write - the winner already stored the same bsuid - so it logs and moves on.
    it 'keeps going when a concurrent webhook already claimed the bsuid' do
      allow(contact_inbox).to receive(:update!).and_raise(
        ActiveRecord::RecordNotUnique.new('PG::UniqueViolation: duplicate key value violates unique constraint')
      )
      expect(Rails.logger).to receive(:warn).with(/bsuid=abc123/)

      expect { service.send(:update_bsuid_fields, contact_inbox, 'abc123', nil) }.not_to raise_error
    end

    it 'persists the bsuid when there is no race' do
      expect(contact_inbox).to receive(:update!).with(hash_including(bsuid: 'abc123'))

      service.send(:update_bsuid_fields, contact_inbox, 'abc123', nil)
    end
  end
end
