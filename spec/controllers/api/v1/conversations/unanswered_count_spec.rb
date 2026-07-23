# frozen_string_literal: true

require 'rails_helper'

# EVO-1963: the sidebar badge counts the CURRENT USER's OPEN conversations that are
# awaiting THEIR reply (waiting_since present). It replaced an account/inbox-wide
# UNREAD count that never zeroed and dropped read-but-unanswered conversations.
RSpec.describe Api::V1::ConversationsController, type: :controller do
  let(:user) { User.create!(email: "agent-#{SecureRandom.hex(4)}@example.com", name: 'Agent') }
  let(:other) { User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", name: 'Other') }
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }

  # Force exact state via update_columns so message/conversation lifecycle callbacks
  # don't rewrite waiting_since out from under the test.
  def conversation(assignee:, status: :open, waiting: true)
    conv = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    conv.update_columns(
      assignee_id: assignee&.id,
      status: Conversation.statuses[status],
      waiting_since: waiting ? 1.hour.ago : nil
    )
    conv
  end

  before do
    allow(controller).to receive(:authenticate_request!).and_return(true)
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
  end
end
