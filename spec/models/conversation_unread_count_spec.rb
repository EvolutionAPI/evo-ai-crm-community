# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversation, '#unread_incoming_messages_count' do
  let(:incoming_relation) { double('IncomingRelation') }
  let(:messages_relation) { double('MessagesRelation', incoming: incoming_relation) }
  let(:conversation) { described_class.new }

  before do
    allow(conversation).to receive(:messages).and_return(messages_relation)
  end

  context 'when agent_last_seen_at is blank' do
    before { conversation.agent_last_seen_at = nil }

    it 'counts every incoming message without filtering by timestamp' do
      expect(incoming_relation).to receive(:count).and_return(7)
      expect(conversation.unread_incoming_messages_count).to eq(7)
    end
  end

  context 'when agent_last_seen_at is present' do
    let(:seen_at) { Time.zone.parse('2026-06-03 12:00:00') }
    let(:filtered_relation) { double('FilteredRelation') }

    before { conversation.agent_last_seen_at = seen_at }

    it 'counts only incoming messages created after agent_last_seen_at (no cap)' do
      expect(incoming_relation).to receive(:where)
        .with('created_at > ?', seen_at)
        .and_return(filtered_relation)
      expect(filtered_relation).to receive(:count).and_return(42)

      expect(conversation.unread_incoming_messages_count).to eq(42)
    end
  end
end
