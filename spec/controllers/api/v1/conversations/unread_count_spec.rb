# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe Api::V1::ConversationsController do
    it 'has controller spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Api::V1::ConversationsController, type: :controller do
  describe '#unread_count' do
    let(:account) { instance_double(Account) }
    let(:user) { instance_double(User, role: 'agent') }
    let(:base_conversations) { double('ConversationsRelation') }
    let(:permitted_conversations) { double('PermittedRelation') }
    let(:filter_service) { instance_double(Conversations::PermissionFilterService, perform: permitted_conversations) }
    let(:joined) { double('Joined') }
    let(:incoming_filtered) { double('IncomingFiltered') }
    let(:since_filtered) { double('SinceFiltered') }
    let(:read_filtered) { double('ReadFiltered', count: 17) }

    before do
      allow(Current).to receive(:account).and_return(account)
      allow(Current).to receive(:user).and_return(user)
      allow(account).to receive(:conversations).and_return(base_conversations)
      allow(Conversations::PermissionFilterService).to receive(:new)
        .with(base_conversations, user).and_return(filter_service)

      allow(permitted_conversations).to receive(:joins).with(:messages).and_return(joined)
      allow(joined).to receive(:where)
        .with(messages: { message_type: Message.message_types[:incoming] })
        .and_return(incoming_filtered)
      allow(incoming_filtered).to receive(:where)
        .with('messages.created_at > COALESCE(conversations.agent_last_seen_at, to_timestamp(0))')
        .and_return(since_filtered)
      allow(since_filtered).to receive(:where)
        .with("messages.content_attributes->>'read' IS DISTINCT FROM 'true'")
        .and_return(read_filtered)
    end

    it 'returns the total unread count across accessible conversations' do
      expect(controller).to receive(:success_response).with(
        hash_including(data: { unread_count: 17 })
      )
      controller.send(:unread_count)
    end

    it 'scopes by current user via PermissionFilterService' do
      allow(controller).to receive(:success_response)
      controller.send(:unread_count)
      expect(Conversations::PermissionFilterService).to have_received(:new).with(base_conversations, user)
    end
  end
end
