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

  describe '#apply_permission_filter' do
    let(:relation) { double('Relation') }

    # AC3: the admin / conversations.read short-circuit must keep returning the
    # untouched relation (no inbox scoping at all).
    it 'returns the query untouched for an admin (short-circuit)' do
      user = instance_double(User, id: 1, administrator?: true)
      finder = described_class.new(user, {})

      expect(relation).not_to receive(:where)
      expect(finder.send(:apply_permission_filter, relation)).to eq(relation)
    end

    # AC1 + AC2: a non-admin user is scoped by `assigned_inboxes`, the role-aware
    # source — NOT the raw `inboxes` relation that returned [] for any user with
    # no inbox_member (the 0/74 bug). `assigned_inboxes` returns Inbox.all for an
    # admin / unassigned member, and only the assigned inboxes for an assigned one.
    it 'scopes a non-admin user by assigned_inboxes (not raw inboxes)' do
      assigned = double('AssignedInboxes')
      user = instance_double(User, id: 2, administrator?: false, assigned_inboxes: assigned)
      finder = described_class.new(user, {})
      scoped = double('Scoped')

      expect(user).not_to receive(:inboxes)
      expect(relation).to receive(:where).with(inbox: assigned).and_return(scoped)

      expect(finder.send(:apply_permission_filter, relation)).to eq(scoped)
    end
  end
end
