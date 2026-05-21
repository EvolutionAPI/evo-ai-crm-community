# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WebhookJob do
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
      actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => ['https://example.com/hook'] }]
    )
  end
  let(:execution) do
    MacroExecution.create!(
      macro: macro,
      conversation: conversation,
      user: user,
      status: :pending,
      actions_result: [{ 'action' => 'send_webhook_event', 'status' => 'enqueued' }]
    )
  end

  before do
    allow(Rails.configuration.dispatcher).to receive(:dispatch)
  end

  describe '#perform without macro_execution_id' do
    it 'is a no-op for MacroExecution and does not dispatch events' do
      allow(Webhooks::Trigger).to receive(:execute)

      expect(MacroExecution).not_to receive(:find_by)
      expect(Rails.configuration.dispatcher).not_to receive(:dispatch)

      described_class.new.perform('https://example.com/hook', { foo: 1 }, :account_webhook)
    end
  end

  describe '#perform on success with macro_execution_id' do
    it 'marks the execution as success and dispatches the completion event' do
      allow(Webhooks::Trigger).to receive(:execute)

      expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
        Events::Types::MACRO_EXECUTION_COMPLETED,
        anything,
        hash_including(macro_execution: execution)
      )

      described_class.new.perform('https://example.com/hook', { foo: 1 }, :macro_webhook, execution.id)

      execution.reload
      expect(execution.status).to eq('success')
      expect(execution.actions_result.first['status']).to eq('success')
    end

    it 'leaves a non-pending execution untouched' do
      execution.update!(status: :failed, completed_at: Time.current, error_message: 'prior')
      allow(Webhooks::Trigger).to receive(:execute)

      expect { described_class.new.perform('https://example.com/hook', {}, :macro_webhook, execution.id) }
        .not_to(change { execution.reload.status })
    end
  end

  describe '#perform on failure with macro_execution_id' do
    it 'marks the execution as failed, stores the error, and dispatches the event' do
      allow(Webhooks::Trigger).to receive(:execute).and_raise(StandardError, 'connection refused')

      expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
        Events::Types::MACRO_EXECUTION_COMPLETED,
        anything,
        hash_including(macro_execution: execution)
      )

      expect do
        described_class.new.perform('https://example.com/hook', {}, :macro_webhook, execution.id)
      end.to raise_error(StandardError, 'connection refused')

      execution.reload
      expect(execution.status).to eq('failed')
      expect(execution.error_message).to include('connection refused')
      expect(execution.actions_result.first['status']).to eq('failed')
    end
  end
end
