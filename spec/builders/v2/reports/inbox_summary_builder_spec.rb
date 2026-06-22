# frozen_string_literal: true

require 'rails_helper'

# T4.4 — InboxSummaryBuilder emits stats only for inboxes the caller can see
# (Current.user.assigned_inboxes), degrading to all inboxes when no request user
# is set. The grouped conversation-count query stays global by design.
RSpec.describe V2::Reports::InboxSummaryBuilder do
  let!(:inbox_a) { Inbox.create!(name: 'Inbox A', channel: Channel::Api.create!) }
  let!(:inbox_b) { Inbox.create!(name: 'Inbox B', channel: Channel::Api.create!) }
  let(:user) { User.create!(name: 'Agent', email: "a-#{SecureRandom.hex(4)}@example.com") }

  let(:builder_params) do
    {
      since: 1.week.ago.to_i.to_s,
      until: Time.current.to_i.to_s,
      business_hours: false
    }
  end

  before { Current.reset }
  after { Current.reset }

  def reported_inbox_ids
    described_class.new(account: nil, params: builder_params).build.map { |row| row[:id] }
  end

  context 'when the user is restricted to inbox A' do
    before do
      InboxMember.create!(inbox: inbox_a, user: user)
      Current.user = user
      Current.evo_role_key = 'agent_restricted'
      Current.evo_can_read_all_inboxes = false
    end

    it 'reports only the assigned inbox' do
      expect(reported_inbox_ids).to contain_exactly(inbox_a.id)
    end
  end

  context 'when an admin is set' do
    before do
      InboxMember.create!(inbox: inbox_a, user: user)
      Current.user = user
      Current.evo_role_key = 'super_admin'
    end

    it 'reports all inboxes' do
      expect(reported_inbox_ids).to contain_exactly(inbox_a.id, inbox_b.id)
    end
  end

  context 'when there is no request user' do
    it 'degrades to reporting all inboxes' do
      expect(reported_inbox_ids).to contain_exactly(inbox_a.id, inbox_b.id)
    end
  end
end
