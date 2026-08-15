# frozen_string_literal: true

require 'rails_helper'

# CRM-171 — for the 5 CONVERSATION_UPDATE_EVENTS, ActionCableBroadcastJob
# already re-fetches the conversation and rebuilds push_event_data from
# scratch (to avoid stale data on out-of-order delivery). Building
# push_event_data in the listener too was pure waste: a second `labels`
# query, plus a much larger Sidekiq/Redis payload thrown away unread. The
# listener now passes only the id for these events.
#
# Kept in its own file (not spec/listeners/action_cable_listener_spec.rb) so
# it can be added to spec-staleness-guard.yml's allowlist without dragging in
# that file's unrelated, pre-existing CB-3 failures.
RSpec.describe ActionCableListener do
  let(:listener) { described_class.instance }
  let(:user) { User.create!(name: 'CU Agent', email: "listener-cu-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://listener-cu.example.com') }
  # An inbox with no members makes user_tokens return [] — conversation_read/
  # team_changed/assignee_changed broadcast only via user_tokens, so blank
  # tokens make `broadcast` return early (see action_cable_listener.rb) and
  # `ActionCableBroadcastJob.perform_later` is never called for THIS event.
  # Without a member, the payload capture below would instead pick up the
  # real conversation.created broadcast (Conversation#after_create_commit
  # publishes it via Wisper independently of anything this spec calls), which
  # still carries the full push_event_data and would make the assertion pass
  # for the wrong reason.
  let(:inbox) do
    ib = Inbox.create!(name: 'Listener CU Inbox', channel: channel)
    InboxMember.create!(inbox: ib, user: user)
    ib
  end
  let(:contact) { Contact.create!(name: 'LCU', email: "lcu-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: "lcu-#{SecureRandom.hex(4)}") }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def build_event(data)
    Struct.new(:data).new(data)
  end

  describe 'conversation update events pass only the identifier' do
    before { Current.reset }
    after  { Current.reset }

    listener_methods = {
      Events::Types::CONVERSATION_READ => :conversation_read,
      Events::Types::CONVERSATION_UPDATED => :conversation_updated,
      Events::Types::TEAM_CHANGED => :team_changed,
      Events::Types::ASSIGNEE_CHANGED => :assignee_changed,
      Events::Types::CONVERSATION_STATUS_CHANGED => :conversation_status_changed
    }

    listener_methods.each do |event_name, listener_method|
      it "enqueues #{listener_method} (#{event_name}) with only {id:}, not a rebuilt push_event_data" do
        payload = nil
        allow(ActionCableBroadcastJob).to receive(:perform_later) do |_tokens, _event, data|
          payload = data
        end

        listener.public_send(listener_method, build_event({ conversation: conversation }))

        expect(payload).to eq(id: conversation.id)
      end
    end
  end

  describe 'conversation update round trip — listener enqueue + job rebuild' do
    before { Current.reset }
    after  { Current.reset }

    let(:labeled_conversation) do
      c = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      c.update!(label_list: 'vip')
      c
    end

    def count_tagging_queries(&)
      count = 0
      subscriber = lambda do |*args|
        sql = args.last[:sql]
        count += 1 if sql.match?(/taggings/i)
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
      count
    end

    it 'costs exactly one labels query end-to-end (two before this fix) and the frame reaches the browser unchanged' do
      job_args = nil
      allow(ActionCableBroadcastJob).to receive(:perform_later) do |*args|
        job_args = args
      end

      listener.conversation_updated(build_event({ conversation: labeled_conversation }))
      expect(job_args).not_to be_nil

      broadcast_data = nil
      allow(ActionCable.server).to receive(:broadcast) do |_token, payload|
        broadcast_data = payload[:data]
      end

      tag_queries = count_tagging_queries { ActionCableBroadcastJob.perform_now(*job_args) }

      # One query: the listener no longer builds push_event_data (0), the job's
      # rebuild does it once (1). Before this fix both builds ran: 2.
      expect(tag_queries).to eq(1)

      # Non-regression (CRM-155): the label reaches the browser without a
      # reload, and the rest of the frame is unchanged from a fresh build —
      # the identifier-only payload didn't shrink what actually gets sent.
      expect(broadcast_data[:labels]).to eq(['vip'])
      expect(broadcast_data).to eq(Conversation.find(labeled_conversation.id).push_event_data)
    end
  end
end
