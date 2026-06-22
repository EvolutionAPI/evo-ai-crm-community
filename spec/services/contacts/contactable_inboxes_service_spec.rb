# frozen_string_literal: true

require 'rails_helper'

# T4.4 — ContactableInboxesService scopes the inbox iteration to the current
# user's assigned_inboxes, degrading to all inboxes when no request user is set
# (it also runs from a background job via StageInactivityTargetResolver).
RSpec.describe Contacts::ContactableInboxesService do
  let!(:inbox_a) { Inbox.create!(name: 'Inbox A', channel: Channel::Api.create!) }
  let!(:inbox_b) { Inbox.create!(name: 'Inbox B', channel: Channel::Api.create!) }
  let(:contact) { Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@example.com") }
  let(:user) { User.create!(name: 'Agent', email: "a-#{SecureRandom.hex(4)}@example.com") }

  before do
    # Give the contact a usable source_id on both inboxes so both would otherwise
    # be returned as contactable (Api channel uses a generated source_id).
    ContactInbox.create!(contact: contact, inbox: inbox_a, source_id: SecureRandom.hex(8))
    ContactInbox.create!(contact: contact, inbox: inbox_b, source_id: SecureRandom.hex(8))
    Current.reset
  end

  after { Current.reset }

  def contactable_inbox_ids
    described_class.new(contact: contact).get.map { |c| c[:inbox].id }
  end

  context 'when the user is restricted to inbox A' do
    before do
      InboxMember.create!(inbox: inbox_a, user: user)
      Current.user = user
      Current.evo_role_key = 'agent_restricted'
      Current.evo_can_read_all_inboxes = false
    end

    it 'returns only the assigned inbox' do
      expect(contactable_inbox_ids).to contain_exactly(inbox_a.id)
    end
  end

  context 'when there is no request user (background job context)' do
    it 'degrades to all inboxes instead of raising' do
      expect(contactable_inbox_ids).to contain_exactly(inbox_a.id, inbox_b.id)
    end
  end
end
