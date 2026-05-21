# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Macros::ExecutionService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:macro) do
    Macro.create!(
      name: 'Test macro',
      created_by: user,
      updated_by: user,
      actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => ['https://webhook.site/abc'] }]
    )
  end

  describe '#send_webhook_event' do
    let(:service) { described_class.new(macro, conversation, user) }
    let(:execution) { MacroExecution.create!(macro: macro, conversation: conversation, user: user, status: :pending) }

    before { service.instance_variable_set(:@execution, execution) }

    it 'enqueues WebhookJob with stripped URL, payload, :macro_webhook and the execution id' do
      expect(WebhookJob).to receive(:perform_later).with(
        'https://webhook.site/abc',
        hash_including(event: 'macro.executed'),
        :macro_webhook,
        execution.id
      )

      service.send(:send_webhook_event, ["  https://webhook.site/abc  \t"])
    end

    it 'skips enqueue and warns when the URL is blank' do
      expect(WebhookJob).not_to receive(:perform_later)
      expect(Rails.logger).to receive(:warn).with(/skipping send_webhook_event/)

      service.send(:send_webhook_event, ['   '])
    end

    it 'skips enqueue when params is nil' do
      expect(WebhookJob).not_to receive(:perform_later)
      service.send(:send_webhook_event, nil)
    end
  end

  describe '#perform' do
    let(:service) { described_class.new(macro, conversation, user) }

    before do
      allow(WebhookJob).to receive(:perform_later)
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    context 'with a webhook action' do
      it 'creates a MacroExecution and leaves it pending while WebhookJob runs async' do
        execution = service.perform

        expect(execution).to be_persisted
        expect(execution.status).to eq('pending')
        expect(execution.actions_result.first['status']).to eq('enqueued')
      end

      it 'does not dispatch the completion event when work is still pending' do
        expect(Rails.configuration.dispatcher).not_to receive(:dispatch)
          .with(Events::Types::MACRO_EXECUTION_COMPLETED, anything, anything)

        service.perform
      end
    end

    context 'with a synchronous action that fails' do
      let(:macro) do
        Macro.create!(
          name: 'Test macro',
          created_by: user,
          updated_by: user,
          actions: [{ 'action_name' => 'send_message', 'action_params' => ['hello'] }]
        )
      end

      before do
        allow(service).to receive(:send_message).and_raise(StandardError, 'boom')
      end

      it 'marks execution as failed and dispatches completion event' do
        expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
          Events::Types::MACRO_EXECUTION_COMPLETED,
          anything,
          hash_including(:macro_execution)
        )

        expect { service.perform }.not_to raise_error
        execution = MacroExecution.last
        expect(execution.status).to eq('failed')
        expect(execution.actions_result.first['status']).to eq('failed')
      end
    end
  end
end
