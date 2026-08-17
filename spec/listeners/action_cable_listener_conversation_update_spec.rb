# frozen_string_literal: true

require 'rails_helper'

# ActionCableBroadcastJob rebuilds push_event_data for
# CONVERSATION_UPDATE_EVENTS, so the listener only passes the id. Split from
# action_cable_listener_spec.rb, whose failures keep it out of the CI guard.
RSpec.describe ActionCableListener do
  let(:listener) { described_class.instance }
  let(:user) { User.create!(name: 'CU Agent', email: "listener-cu-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://listener-cu.example.com') }
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
      it "enqueues #{listener_method} (#{event_name}) with only the conversation id" do
        payload = nil
        # Creating the conversation fires a real conversation.created into the
        # same mock, so capture only this event.
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

    # Counts the push_labels_data lookup, one per push_event_data build. The
    # acts_as_taggable `label_list` load hits `taggings` and costs 1 per
    # instance regardless, so it cannot tell the two builds apart.
    def count_label_queries(&)
      count = 0
      subscriber = lambda do |*args|
        sql = args.last[:sql]
        count += 1 if sql.match?(/FROM "labels"/i)
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
      count
    end

    it 'resolves labels once across the round trip and broadcasts the whole frame' do
      labeled_conversation # created outside the counter: create/update fire their own events

      job_args = nil
      allow(ActionCableBroadcastJob).to receive(:perform_later) do |*args|
        job_args = args
      end
      broadcast_data = nil
      allow(ActionCable.server).to receive(:broadcast) do |_token, payload|
        broadcast_data = payload[:data]
      end

      # Both halves sit inside the counter: the listener is where a second
      # build would happen, so measuring the job alone always counts 1.
      label_queries = count_label_queries do
        listener.conversation_updated(build_event({ conversation: labeled_conversation }))
        expect(job_args&.at(1)).to eq(Events::Types::CONVERSATION_UPDATED)
        ActionCableBroadcastJob.perform_now(*job_args)
      end

      expect(label_queries).to eq(1)

      # The frame carries the whole conversation, labels included — the
      # identifier-only payload never reaches the browser.
      expect(broadcast_data[:labels]).to eq(['vip'])
      expect(broadcast_data).to eq(Conversation.find(labeled_conversation.id).push_event_data)
    end
  end

  # Every example materializes a non-member: with an empty users table a global
  # pluck returns the same set as the scoped one and proves nothing.
  describe '#user_tokens (inbox-scoped recipients)' do
    before { Current.reset }
    after  { Current.reset }

    let(:non_member) do
      User.create!(name: 'CU Outsider', email: "listener-cu-out-#{SecureRandom.hex(4)}@test.com")
    end

    it 'returns only the given inbox members pubsub tokens, de-duplicated' do
      non_member

      expect(listener.send(:user_tokens, nil, [user, user])).to eq([user.pubsub_token])
    end

    it 'does NOT leak to a user who is not a member of the inbox' do
      non_member

      tokens = listener.send(:user_tokens, nil, [user])

      expect(tokens).not_to include(non_member.pubsub_token)
      expect(tokens).to eq([user.pubsub_token])
    end

    it 'returns nothing when there are no inbox members (never a global broadcast)' do
      user
      non_member

      expect(listener.send(:user_tokens, nil, [])).to eq([])
    end

    it 'broadcasts a conversation event only to the inbox members' do
      conversation # created before the mock: its own create event uses the real job
      non_member

      tokens = nil
      allow(ActionCableBroadcastJob).to receive(:perform_later) do |broadcast_tokens, event, _data|
        tokens = broadcast_tokens if event == Events::Types::CONVERSATION_UPDATED
      end

      listener.conversation_updated(build_event({ conversation: conversation }))

      expect(tokens).to include(user.pubsub_token)
      expect(tokens).not_to include(non_member.pubsub_token)
    end
  end
end
