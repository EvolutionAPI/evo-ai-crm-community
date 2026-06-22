# frozen_string_literal: true

require 'rails_helper'

# T4.4 — PermissionFilterService now scopes by assigned_inboxes (not raw inboxes)
# so the opt-in default and conversations.read_all are honored consistently. This
# is the shared scoping primitive behind the scoped conversation read paths
# (oauth/conversations#available_for_pipeline, live_reports, pipeline_items).
RSpec.describe Conversations::PermissionFilterService do
  let(:channel_a) { Channel::Api.create! }
  let(:channel_b) { Channel::Api.create! }
  let(:inbox_a) { Inbox.create!(name: 'Inbox A', channel: channel_a) }
  let(:inbox_b) { Inbox.create!(name: 'Inbox B', channel: channel_b) }
  let(:contact) { Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@example.com") }

  let(:conv_a) do
    ci = ContactInbox.create!(contact: contact, inbox: inbox_a, source_id: SecureRandom.hex(8))
    Conversation.create!(inbox: inbox_a, contact: contact, contact_inbox: ci)
  end
  let(:conv_b) do
    ci = ContactInbox.create!(contact: contact, inbox: inbox_b, source_id: SecureRandom.hex(8))
    Conversation.create!(inbox: inbox_b, contact: contact, contact_inbox: ci)
  end

  let(:user) { User.create!(name: 'Agent', email: "a-#{SecureRandom.hex(4)}@example.com") }

  before do
    conv_a
    conv_b
    Current.reset
  end

  after { Current.reset }

  def perform
    described_class.new(Conversation.all, user).perform
  end

  context 'when restricted (no read_all) and assigned to inbox A only' do
    before do
      InboxMember.create!(inbox: inbox_a, user: user)
      Current.evo_role_key = 'agent_restricted'
      Current.evo_can_read_all_inboxes = false
    end

    it 'returns only conversations from inbox A' do
      expect(perform).to contain_exactly(conv_a)
    end
  end

  context 'when the user has no assignment (opt-in default)' do
    before do
      Current.evo_role_key = 'agent_restricted'
      Current.evo_can_read_all_inboxes = false
    end

    it 'returns all conversations' do
      expect(perform).to contain_exactly(conv_a, conv_b)
    end
  end

  context 'when the user has conversations.read_all' do
    before do
      InboxMember.create!(inbox: inbox_a, user: user)
      Current.evo_role_key = 'agent'
      Current.evo_can_read_all_inboxes = true
    end

    it 'returns all conversations despite the single assignment' do
      expect(perform).to contain_exactly(conv_a, conv_b)
    end
  end

  context 'when the user is an administrator' do
    before { Current.evo_role_key = 'super_admin' }

    it 'returns all conversations (early role bypass)' do
      InboxMember.create!(inbox: inbox_a, user: user)
      expect(perform).to contain_exactly(conv_a, conv_b)
    end
  end

  context 'when there is no resolvable user (service context)' do
    it 'degrades to all conversations instead of raising' do
      expect(described_class.new(Conversation.all, nil).perform).to contain_exactly(conv_a, conv_b)
    end
  end
end
