# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MacroExecution do
  subject(:execution) do
    described_class.create!(macro: macro, conversation: conversation, user: user, status: :pending)
  end

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

  describe '#complete!' do
    it 'moves the record from pending to success and stamps completed_at' do
      expect { execution.complete!(actions_result: [{ action: 'send_message', status: 'success' }]) }
        .to change(execution, :status).from('pending').to('success')
      expect(execution.completed_at).to be_present
      expect(execution.actions_result.first['action']).to eq('send_message')
    end
  end

  describe '#fail!' do
    it 'moves the record from pending to failed and stores a truncated error message' do
      long_error = 'x' * 2000
      execution.fail!(error: long_error, actions_result: [])
      expect(execution.status).to eq('failed')
      expect(execution.completed_at).to be_present
      expect(execution.error_message.length).to be <= 1000
    end
  end
end
