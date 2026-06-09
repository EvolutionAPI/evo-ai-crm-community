# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutoAssignment::AgentAssignmentService do
  let(:channel)       { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox)         { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact)       { Contact.create!(name: 'Test Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation)  { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:agent)         { User.create!(name: 'Agent', email: "a-#{SecureRandom.hex(4)}@test.com") }
  let(:agent_ids)     { [agent.id] }

  subject(:service) do
    described_class.new(conversation: conversation, allowed_agent_ids: agent_ids)
  end

  after { EvoExtensionPoints.reset! }

  describe '#find_assignee' do
    context 'without routing_strategy override (default RoundRobin)' do
      let(:mock_service) { instance_double(AutoAssignment::InboxRoundRobinService) }


      before { EvoExtensionPoints.reset! }
      before do
        allow(AutoAssignment::InboxRoundRobinService)
          .to receive(:new)
          .with(inbox: conversation.inbox)
          .and_return(mock_service)
        allow(mock_service)
          .to receive(:available_agent)
          .with(allowed_agent_ids: anything)
          .and_return(agent)
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })
      end

      it 'delegates to AutoAssignment::Strategies::RoundRobin' do
        expect(AutoAssignment::Strategies::RoundRobin)
          .to receive(:call)
          .with(conversation, allowed_agent_ids: anything)
          .and_call_original
        service.find_assignee
      end

      it 'returns the agent selected by RoundRobin' do
        expect(service.find_assignee).to eq(agent)
      end

      it 'logs the routing strategy used' do
        expect(Rails.logger).to receive(:info).with(/\[AgentAssignment\] routing via.*for conversation #{conversation.id}/)
        service.find_assignee
      end
    end

    context 'with routing_strategy override registered' do
      let(:custom_agent) { User.create!(name: 'Custom Agent', email: "custom-#{SecureRandom.hex(4)}@test.com") }

      before do
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })
        EvoExtensionPoints.replace(:routing_strategy) do |_conversation, allowed_agent_ids:|
          custom_agent
        end
      end

      it 'uses the registered override instead of RoundRobin' do
        expect(AutoAssignment::Strategies::RoundRobin).not_to receive(:call)
        expect(service.find_assignee).to eq(custom_agent)
      end

      it 'logs EvoExtensionPoints[:routing_strategy] as the strategy label' do
        expect(Rails.logger).to receive(:info)
          .with(/\[AgentAssignment\] routing via EvoExtensionPoints\[:routing_strategy\] for conversation #{conversation.id}/)
        service.find_assignee
      end
    end
  end
end
