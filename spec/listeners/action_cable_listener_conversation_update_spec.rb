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
  # `user_tokens` ignores its `agents` argument and plucks every User's
  # pubsub_token (action_cable_listener.rb:186), so what keeps these
  # broadcasts alive is a User row existing at all — not the membership.
  # With no User, conversation_read/team_changed/assignee_changed (which
  # resolve recipients through user_tokens alone) hit `return if
  # tokens.blank?` and never enqueue. The captures below only record their
  # own event, so that would fail loudly rather than silently validate the
  # real conversation.created broadcast Conversation#after_create_commit
  # publishes via Wisper.
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
        # Capture only THIS event: creating the conversation fires a real
        # conversation.created through Wisper, which lands in the same mock
        # carrying a full push_event_data.
        allow(ActionCableBroadcastJob).to receive(:perform_later) do |_tokens, event, data|
          payload = data if event == event_name
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

    # The query this counts is `EventDataPresenter#push_labels_data` ->
    # `Label.where(...)`, one per push_event_data build. It is NOT the
    # acts_as_taggable `label_list` load: that one reads `taggings`, and the
    # job's fresh instance makes it cost 1 whether or not the listener also
    # built the payload — counting it would leave this example green on the
    # unfixed listener.
    def count_label_queries(&)
      count = 0
      subscriber = lambda do |*args|
        sql = args.last[:sql]
        count += 1 if sql.match?(/FROM "labels"/i)
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
      count
    end

    it 'costs exactly one labels query end-to-end (two before this fix) and the frame reaches the browser unchanged' do
      labeled_conversation # build it before measuring: create/update fire their own events

      job_args = nil
      allow(ActionCableBroadcastJob).to receive(:perform_later) do |*args|
        job_args = args
      end
      broadcast_data = nil
      allow(ActionCable.server).to receive(:broadcast) do |_token, payload|
        broadcast_data = payload[:data]
      end

      # Both halves of the round trip must sit inside the counter: the build
      # this fix removes happens in the listener, so measuring the job alone
      # counts 1 either way and proves nothing.
      label_queries = count_label_queries do
        listener.conversation_updated(build_event({ conversation: labeled_conversation }))
        expect(job_args&.at(1)).to eq(Events::Types::CONVERSATION_UPDATED)
        ActionCableBroadcastJob.perform_now(*job_args)
      end

      # The job's rebuild resolves the labels once (1). Before this fix the
      # listener resolved them too, for a payload the job then discarded: 2.
      expect(label_queries).to eq(1)

      # Non-regression (CRM-155): the label reaches the browser without a
      # reload. Comparing against a fresh build proves the identifier-only
      # payload never reaches the browser — the job still ships the whole
      # frame — but not parity with the pre-fix frame, which the job already
      # discarded before this change.
      expect(broadcast_data[:labels]).to eq(['vip'])
      expect(broadcast_data).to eq(Conversation.find(labeled_conversation.id).push_event_data)
    end
  end
end
