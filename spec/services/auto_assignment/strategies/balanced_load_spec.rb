# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutoAssignment::Strategies::BalancedLoad do
  let(:channel)       { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox)         { Inbox.create!(name: 'BL Test Inbox', channel: channel) }
  let(:contact)       { Contact.create!(name: 'Test Contact', email: "bl-c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:agent1)        { User.create!(name: 'Agent1', email: "bl-a1-#{SecureRandom.hex(4)}@test.com") }
  let(:agent2)        { User.create!(name: 'Agent2', email: "bl-a2-#{SecureRandom.hex(4)}@test.com") }

  def make_conversation(assignee:, status: :open)
    conv = Conversation.create!(
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      assignee: assignee
    )
    conv.update_columns(status: Conversation.statuses[status.to_s]) unless status == :open
    conv
  end

  describe '.call' do
    subject(:result) { described_class.call(nil, allowed_agent_ids: agent_ids) }

    context 'when allowed_agent_ids is empty' do
      let(:agent_ids) { [] }

      it 'returns nil without querying the database' do
        expect(Conversation).not_to receive(:where)
        expect(result).to be_nil
      end
    end

    context 'when IDs are Strings (simulating Redis)' do
      let(:agent_ids) { [agent1.id.to_s] }

      it 'handles String UUID IDs and returns a User' do
        expect(result).to be_a(User)
        expect(result).to eq(agent1)
      end
    end

    context 'when agent2 has more open conversations than agent1' do
      let(:agent_ids) { [agent1.id, agent2.id] }

      before do
        3.times { make_conversation(assignee: agent2, status: :open) }
      end

      it 'selects agent1 (lower load)' do
        expect(result).to eq(agent1)
      end
    end

    context 'when agent1 has more open conversations than agent2' do
      let(:agent_ids) { [agent1.id, agent2.id] }

      before do
        5.times { make_conversation(assignee: agent1, status: :open) }
      end

      it 'selects agent2 (lower load)' do
        expect(result).to eq(agent2)
      end
    end

    context 'when resolved conversations are not counted' do
      let(:agent_ids) { [agent1.id, agent2.id] }

      before do
        4.times { make_conversation(assignee: agent1, status: :resolved) }
        2.times { make_conversation(assignee: agent2, status: :open) }
      end

      it 'selects agent1 (resolved convs do not count toward load)' do
        expect(result).to eq(agent1)
      end
    end

    context 'when min_id resolves to a deleted user' do
      let(:agent_ids) { [agent1.id] }

      it 'returns nil via User.find_by (no RecordNotFound raised)' do
        allow(User).to receive(:find_by).and_return(nil)
        expect { result }.not_to raise_error
        expect(result).to be_nil
      end
    end

    context 'with a single query (no N+1)' do
      let(:agent_ids) { [agent1.id.to_s, agent2.id.to_s] }

      it 'calls Conversation.where exactly once (no per-agent queries)' do
        relation = instance_double(ActiveRecord::Relation)
        grouped  = instance_double(ActiveRecord::Relation)
        allow(Conversation).to receive(:where).once.and_return(relation)
        allow(relation).to receive(:group).and_return(grouped)
        allow(grouped).to receive(:count).and_return({})
        allow(User).to receive(:find_by).and_return(agent1)

        described_class.call(nil, allowed_agent_ids: agent_ids)

        expect(Conversation).to have_received(:where).once
      end
    end
  end
end
