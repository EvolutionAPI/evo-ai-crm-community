# frozen_string_literal: true

require 'rails_helper'

# EVO-1963: the sidebar badge counts the CURRENT USER's conversations that are awaiting
# THEIR reply — Conversation.unanswered (open, not archived, waiting_since present)
# restricted to the assignee, through the same permission gate as the list. It replaced
# an account/inbox-wide UNREAD count that never zeroed and dropped read-but-unanswered
# conversations. Every example below pins one clause of that sentence; the number the
# badge shows and the rows the click lists must be the same set.
RSpec.describe Api::V1::ConversationsController, type: :controller do
  let(:user) { User.create!(email: "agent-#{SecureRandom.hex(4)}@example.com", name: 'Agent') }
  let(:other) { User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", name: 'Other') }
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:other_channel) { Channel::Api.create! }
  let(:other_inbox) { Inbox.create!(name: 'Other inbox', channel: other_channel) }

  # Force exact state via update_columns so message/conversation lifecycle callbacks
  # don't rewrite waiting_since out from under the test.
  def conversation(assignee:, status: :open, waiting: true, archived: false, in_inbox: nil)
    box = in_inbox || inbox
    ci = box == inbox ? contact_inbox : ContactInbox.create!(contact: contact, inbox: box, source_id: SecureRandom.hex(8))
    conv = Conversation.create!(inbox: box, contact: contact, contact_inbox: ci)
    conv.update_columns(
      assignee_id: assignee&.id,
      status: Conversation.statuses[status],
      waiting_since: waiting ? 1.hour.ago : nil,
      custom_attributes: archived ? { 'archived' => true } : {}
    )
    conv
  end

  before do
    allow(controller).to receive(:authenticate_request!).and_return(true)
    # An agent only sees an inbox they are a member of (User#assigned_inboxes has no
    # zero-membership fallback), and the count goes through the same gate as the
    # list — so the membership has to exist for anything to be visible at all.
    InboxMember.create!(inbox: inbox, user: user)
    Current.user = user
    Current.service_authenticated = true # bypass the require_permissions gate
  end

  after { Current.reset }

  describe '#unanswered_count' do
    it 'counts only my open conversations that are awaiting my reply' do
      conversation(assignee: user, waiting: true)                       # counts
      conversation(assignee: user, waiting: false)                      # I already replied -> no
      conversation(assignee: user, status: :resolved, waiting: true)    # resolved -> no
      conversation(assignee: other, waiting: true)                      # not mine -> no

      get :unanswered_count

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(1)
    end

    it 'keeps counting a conversation that was read but not replied to' do
      # The regression this guards: opening/reading must NOT decrement the badge —
      # only a human reply (which clears waiting_since) does.
      conversation(assignee: user, waiting: true)

      get :unanswered_count

      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(1)
    end

    it 'is zero when the user has none awaiting reply' do
      conversation(assignee: user, waiting: false)

      get :unanswered_count

      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(0)
    end

    # The root cause of the card: the old query ran through PermissionFilterService,
    # which returns EVERYTHING for an administrator — so an admin saw the whole
    # account's number and it never moved as they worked. Scoping by assignee has to
    # hold for the admin too, not just for a restricted agent.
    it 'stays scoped to me for an administrator' do
      Current.evo_role_key = 'super_admin'
      conversation(assignee: user, waiting: true)
      conversation(assignee: other, waiting: true) # another agent's — not mine

      get :unanswered_count

      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(1)
    end

    # The list hides archived conversations client-side, so counting them here would
    # make the badge promise rows the click can't show.
    it 'does not count an archived conversation' do
      conversation(assignee: user, waiting: true, archived: true)

      get :unanswered_count

      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(0)
    end

    # ConversationFinder scopes the list to assigned_inboxes for a non-admin. Counting
    # a conversation the list would hide is exactly the "badge says 3, list shows 2"
    # divergence the card forbids.
    it 'does not count a conversation in an inbox I no longer have access to' do
      conversation(assignee: user, waiting: true, in_inbox: other_inbox)

      get :unanswered_count

      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(0)
    end

    # Service-token calls arrive with service_authenticated but no Current.user.
    # "Mine" is meaningless there — answer zero, never raise (assigned_to(nil) would
    # blow up on nil.id and surface as a 500).
    it 'answers zero instead of raising when there is no resolvable user' do
      conversation(assignee: user, waiting: true)
      Current.user = nil

      get :unanswered_count

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(0)
    end
  end
end
