# frozen_string_literal: true

require 'rails_helper'

# Regression guard for AutoAssignment::Strategies::RoundRobin (Story 1.1).
#
# Verifies that the RoundRobin strategy facade produces identical results to
# calling AutoAssignment::InboxRoundRobinService directly.  This spec is a
# MERGE GATE: if behaviour diverges for the same inputs the PR must NOT merge.
RSpec.describe AutoAssignment::Strategies::RoundRobin do
  let(:channel)       { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox)         { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact)       { Contact.create!(name: 'Test Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation)  { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:agent)         { User.create!(name: 'Agent', email: "a-#{SecureRandom.hex(4)}@test.com") }

  # -----------------------------------------------------------------------
  # Regression guard: conversation.inbox must equal the inbox attribute used
  # by InboxRoundRobinService so the facade is a true equivalent.
  # -----------------------------------------------------------------------
  it 'conversation.inbox equals the inbox passed to InboxRoundRobinService' do
    expect(conversation.inbox).to eq(inbox)
  end

  describe '.call' do
    subject(:result) { described_class.call(conversation, allowed_agent_ids: agent_ids) }

    context 'when allowed_agent_ids is empty' do
      let(:agent_ids) { [] }

      it 'returns nil' do
        expect(result).to be_nil
      end
    end

    context 'when allowed_agent_ids is nil-like (blank)' do
      let(:agent_ids) { nil }

      it 'returns nil without raising' do
        expect { result }.not_to raise_error
        expect(result).to be_nil
      end
    end

    context 'when InboxRoundRobinService returns an agent' do
      let(:agent_ids) { [agent.id.to_s] }
      let(:mock_service) { instance_double(AutoAssignment::InboxRoundRobinService) }

      before do
        allow(AutoAssignment::InboxRoundRobinService)
          .to receive(:new)
          .with(inbox: conversation.inbox)
          .and_return(mock_service)

        allow(mock_service)
          .to receive(:available_agent)
          .with(allowed_agent_ids: agent_ids)
          .and_return(agent)
      end

      it 'returns the same User as InboxRoundRobinService' do
        expect(result).to eq(agent)
      end

      it 'passes allowed_agent_ids unchanged to InboxRoundRobinService' do
        expect(mock_service).to receive(:available_agent).with(allowed_agent_ids: agent_ids)
        result
      end
    end

    context 'when InboxRoundRobinService returns nil (no agent available)' do
      let(:agent_ids) { [agent.id.to_s] }
      let(:mock_service) { instance_double(AutoAssignment::InboxRoundRobinService) }

      before do
        allow(AutoAssignment::InboxRoundRobinService)
          .to receive(:new)
          .with(inbox: conversation.inbox)
          .and_return(mock_service)

        allow(mock_service)
          .to receive(:available_agent)
          .with(allowed_agent_ids: agent_ids)
          .and_return(nil)
      end

      it 'returns nil' do
        expect(result).to be_nil
      end
    end
  end
end
