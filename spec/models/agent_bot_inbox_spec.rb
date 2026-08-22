# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBotInbox do
  describe '#set_default_configurations' do
    it 'defaults status to active when status is not set' do
      agent_bot_inbox = described_class.new

      agent_bot_inbox.send(:set_default_configurations)

      expect(agent_bot_inbox.status).to eq('active')
    end

    it 'does not override an explicit status' do
      agent_bot_inbox = described_class.new(status: :inactive)

      agent_bot_inbox.send(:set_default_configurations)

      expect(agent_bot_inbox.status).to eq('inactive')
    end
  end

  # CRM-212: the operator sees "the AI stopped answering after I moved the card"
  # and the log only said "does not match configuration criteria
  # (status/labels/ignored_labels)" — which of the three rejected, and with which
  # values, was invisible. These lock the reason down so the log can name it.
  describe '#processing_block_reason' do
    let(:conversation) { instance_double(Conversation, id: 'conv-1', status: 'open') }

    it 'names the status rule and the configured list when the status is not allowed' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: ['pending'])

      reason = agent_bot_inbox.processing_block_reason(conversation)

      expect(reason).to include('status "open"')
      expect(reason).to include('allowed_conversation_statuses=["pending"]')
    end

    # The default is the case that bites in production: nothing is configured, so
    # only `pending` passes and the bot goes quiet as soon as an agent takes the
    # conversation (status becomes `open`).
    it 'spells out that the default is pending-only when nothing is configured' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: [])

      reason = agent_bot_inbox.processing_block_reason(conversation)

      expect(reason).to include('pending (default: none configured)')
    end

    it 'reports the ignored label before any other rule' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: ['open'], ignored_label_ids: ['7'])
      allow(agent_bot_inbox).to receive(:resolve_label_ids_for_conversation).and_return(['7'])

      expect(agent_bot_inbox.processing_block_reason(conversation)).to include('ignored_label present')
    end

    it 'reports the allowed-label rule when the conversation carries none of them' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: ['open'], allowed_label_ids: ['9'])
      allow(agent_bot_inbox).to receive(:resolve_label_ids_for_conversation).and_return(['3'])

      expect(agent_bot_inbox.processing_block_reason(conversation)).to include('no allowed label')
    end

    it 'returns nil when the conversation is eligible' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: %w[pending open])

      expect(agent_bot_inbox.processing_block_reason(conversation)).to be_nil
    end

    it 'keeps should_process_conversation? in sync with the reason' do
      blocked = described_class.new(allowed_conversation_statuses: ['pending'])
      eligible = described_class.new(allowed_conversation_statuses: ['open'])

      expect(blocked.should_process_conversation?(conversation)).to be(false)
      expect(eligible.should_process_conversation?(conversation)).to be(true)
    end
  end
end
