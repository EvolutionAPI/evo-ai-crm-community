# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ConversationFinder do
  describe '#apply_sorting' do
    it 'defaults to last_activity_at desc when sort_by is missing' do
      user = instance_double(User, id: 1, administrator?: false)
      finder = described_class.new(user, {})
      relation = double('Relation')

      expect(relation).to receive(:sort_on_last_activity_at).with('desc').and_return(relation)

      finder.send(:apply_sorting, relation)
    end

    it 'uses provided sort_by when available' do
      user = instance_double(User, id: 1, administrator?: false)
      finder = described_class.new(user, { sort_by: 'created_at_asc' })
      relation = double('Relation')

      expect(relation).to receive(:sort_on_created_at).with('asc').and_return(relation)

      finder.send(:apply_sorting, relation)
    end
  end

  # EVO-1958: `agent_bot_inbox` must be preloaded off `inbox` so the serializer
  # can resolve `Inbox#active_bot?` (called per conversation in the list
  # serializer, see conversation_serializer.rb:84) in memory rather than firing
  # a per-inbox SELECT against agent_bot_inboxes — and without re-emitting the
  # per-conversation INFO log that used to live in `Inbox#active_bot?`.
  describe 'conversation list eager-loading (agent_bot_inbox)' do
    let(:channel) { Channel::Api.create! }
    let(:inbox) { Inbox.create!(name: 'Inbox', channel: channel) }
    let(:contact) { Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@example.com") }
    let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
    let(:user) { User.create!(name: 'Admin', email: "a-#{SecureRandom.hex(4)}@example.com") }

    before do
      AgentBot.create!(name: 'Bot', outgoing_url: 'https://example.test/bot').tap do |bot|
        AgentBotInbox.create!(agent_bot: bot, inbox: inbox, status: :active)
      end
      Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      allow(user).to receive(:administrator?).and_return(true)
    end

    # Build the relation directly instead of via #perform: #perform wraps the
    # query in `rescue StandardError => empty_result`, so a broken/renamed
    # preload would be swallowed and surface only as a misleading
    # "expected [] not to be empty". Loading the relation here lets an
    # AssociationNotFound raise loudly at its real site.
    #
    # status: 'all' bypasses the status filter — the active AgentBotInbox flips
    # new conversations to `pending` via Inbox#default_conversation_status_value,
    # so the default 'open' filter would return [].
    def list_conversations
      described_class.new(user, { status: 'all' }).send(:build_conversations_query).to_a
    end

    it 'eager-loads inbox.agent_bot_inbox on the conversation list query' do
      conversations = list_conversations

      expect(conversations).not_to be_empty
      expect(conversations.first.inbox.association(:agent_bot_inbox).loaded?).to be(true)
    end

    # AC1, literally: reading `active_bot?` per conversation (as the serializer
    # does) must not fire a SELECT against agent_bot_inboxes once preloaded.
    it 'reads active_bot? without firing a per-inbox agent_bot_inboxes query' do
      conversations = list_conversations
      expect(conversations).not_to be_empty

      agent_bot_inbox_queries = []
      subscriber = lambda do |*args|
        sql = args.last[:sql]
        agent_bot_inbox_queries << sql if sql =~ /agent_bot_inboxes/i
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        conversations.each { |conversation| conversation.inbox.active_bot? }
      end

      expect(agent_bot_inbox_queries).to be_empty
    end

    # AC2: reading `active_bot?` in the list path must not re-emit the debug
    # INFO log that previously fired once per conversation on every list render.
    it 'does not re-emit the per-conversation active_bot? INFO log' do
      conversations = list_conversations
      expect(conversations).not_to be_empty

      allow(Rails.logger).to receive(:info).and_call_original
      conversations.each { |conversation| conversation.inbox.active_bot? }

      expect(Rails.logger).not_to have_received(:info).with(/\[Inbox\] active_bot\?/)
    end
  end

  describe '#apply_permission_filter' do
    let(:relation) { double('Relation') }

    # AC3: the admin short-circuit must keep returning the untouched relation (no
    # inbox scoping at all). The dead `conversations.read` branch was removed
    # (#179/#183) — only admins short-circuit now.
    it 'returns the query untouched for an admin (short-circuit)' do
      user = instance_double(User, id: 1, administrator?: true)
      finder = described_class.new(user, {})

      expect(relation).not_to receive(:where)
      expect(finder.send(:apply_permission_filter, relation)).to eq(relation)
    end

    # AC1 + AC2: a non-admin user is scoped by `assigned_inboxes`, the role-aware
    # source — NOT the raw `inboxes` relation that returned [] for any user with
    # no inbox_member (the 0/74 bug). `assigned_inboxes` returns Inbox.all for an
    # admin or a user with conversations.read_all, only the assigned inboxes for an
    # assigned member, and NONE for a member with no assignment (no fallback).
    it 'scopes a non-admin user by assigned_inboxes (not raw inboxes)' do
      assigned = double('AssignedInboxes')
      user = instance_double(User, id: 2, administrator?: false, assigned_inboxes: assigned)
      finder = described_class.new(user, {})
      scoped = double('Scoped')

      expect(user).not_to receive(:inboxes)
      expect(relation).to receive(:where).with(inbox: assigned).and_return(scoped)

      expect(finder.send(:apply_permission_filter, relation)).to eq(scoped)
    end

    # #179/#183 regression: there is no `conversations.read` bypass and no
    # zero-membership fallback. A non-admin is ALWAYS scoped by assigned_inboxes,
    # even when that set is empty (they then see no conversations) — the finder must
    # never short-circuit to the full relation for a non-admin.
    it 'never bypasses inbox scoping for a non-admin, even with no assigned inboxes' do
      empty = double('EmptyAssignedInboxes')
      user = instance_double(User, id: 3, administrator?: false, assigned_inboxes: empty)
      finder = described_class.new(user, {})
      scoped = double('ScopedToNone')

      expect(relation).to receive(:where).with(inbox: empty).and_return(scoped)
      expect(finder.send(:apply_permission_filter, relation)).to eq(scoped)
    end
  end
end
