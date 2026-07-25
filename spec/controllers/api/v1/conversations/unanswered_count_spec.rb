# frozen_string_literal: true

require 'rails_helper'

# The sidebar badge counts Conversation.unanswered restricted to the assignee, through
# the same permission gate as the list — the number and the rows the click lists have to
# be the same set. Each example pins one clause of that.
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
    # User#assigned_inboxes has no zero-membership fallback.
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

    # PermissionFilterService returns everything for an administrator; the assignee
    # scoping has to hold anyway.
    it 'stays scoped to me for an administrator' do
      Current.evo_role_key = 'super_admin'
      conversation(assignee: user, waiting: true)
      conversation(assignee: other, waiting: true) # another agent's — not mine

      get :unanswered_count

      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(1)
    end

    # The list hides archived conversations client-side.
    it 'does not count an archived conversation' do
      conversation(assignee: user, waiting: true, archived: true)

      get :unanswered_count

      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(0)
    end

    # ConversationFinder scopes the list to assigned_inboxes for a non-admin.
    it 'does not count a conversation in an inbox I no longer have access to' do
      conversation(assignee: user, waiting: true, in_inbox: other_inbox)

      get :unanswered_count

      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(0)
    end

    # Service-token calls arrive with no Current.user; assigned_to(nil) would raise.
    it 'answers zero instead of raising when there is no resolvable user' do
      conversation(assignee: user, waiting: true)
      Current.user = nil

      get :unanswered_count

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig('data', 'unanswered_count')).to eq(0)
    end
  end
end
