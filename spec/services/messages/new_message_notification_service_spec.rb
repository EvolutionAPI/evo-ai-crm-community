# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Messages::NewMessageNotificationService' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Messages::NewMessageNotificationService do
  let(:assignee) { instance_double(User) }
  let(:sender) { instance_double(User) }
  let(:participants_relation) { instance_double(ActiveRecord::Relation) }
  let(:notifications_relation) { instance_double(ActiveRecord::Relation, exists?: false) }
  let(:inbox) { instance_double(Inbox, members: []) }
  let(:conversation) do
    instance_double(
      Conversation,
      assignee: assignee,
      conversation_participants: [],
      notifications: notifications_relation,
      created_at: 5.minutes.ago,
      inbox: inbox
    )
  end
  let(:message) do
    instance_double(
      Message,
      conversation: conversation,
      sender: sender,
      notifiable?: true
    )
  end
  let(:notification_builder) { instance_double(NotificationBuilder, perform: true) }

  before do
    allow(NotificationBuilder).to receive(:new).and_return(notification_builder)
  end

  describe '#perform' do
    it 'does not raise NameError when message has no account method (regression EVO-983)' do
      expect { described_class.new(message: message).perform }.not_to raise_error
    end

    it 'returns early when message is not notifiable' do
      allow(message).to receive(:notifiable?).and_return(false)

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new)
    end

    it 'notifies the conversation assignee without passing an account argument' do
      allow(notifications_relation).to receive(:exists?).with(user: assignee, secondary_actor: message).and_return(false)

      described_class.new(message: message).perform

      expect(NotificationBuilder).to have_received(:new).with(
        notification_type: 'assigned_conversation_new_message',
        user: assignee,
        primary_actor: conversation,
        secondary_actor: message
      )
    end

    it 'skips assignee notification when assignee is the sender' do
      allow(conversation).to receive(:assignee).and_return(sender)

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new)
    end

    it 'skips assignee notification when already notified' do
      allow(notifications_relation).to receive(:exists?).with(user: assignee, secondary_actor: message).and_return(true)

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new).with(
        hash_including(notification_type: 'assigned_conversation_new_message')
      )
    end

    it 'notifies participating users excluding the sender' do
      participant = instance_double(User)
      participant_record = instance_double(ConversationParticipant, user: participant)
      sender_record = instance_double(ConversationParticipant, user: sender)
      allow(conversation).to receive_messages(assignee: nil, conversation_participants: [participant_record, sender_record])
      allow(notifications_relation).to receive(:exists?).with(user: participant, secondary_actor: message).and_return(false)

      described_class.new(message: message).perform

      expect(NotificationBuilder).to have_received(:new).with(
        notification_type: 'participating_conversation_new_message',
        user: participant,
        primary_actor: conversation,
        secondary_actor: message
      ).once
    end
  end

  describe '#notify_inbox_members_if_unassigned' do
    let(:member) { instance_double(User, id: 101) }
    let(:notified_relation) { instance_double(ActiveRecord::Relation, pluck: []) }

    before do
      allow(conversation).to receive(:assignee).and_return(nil)
      allow(notifications_relation).to receive(:where).with(secondary_actor: message).and_return(notified_relation)
    end

    it 'notifies every inbox member of an unassigned conversation except the sender' do
      allow(inbox).to receive(:members).and_return([member, sender])

      described_class.new(message: message).perform

      expect(NotificationBuilder).to have_received(:new).with(
        notification_type: 'assigned_conversation_new_message',
        user: member,
        primary_actor: conversation,
        secondary_actor: message
      ).once
      expect(NotificationBuilder).not_to have_received(:new).with(hash_including(user: sender))
    end

    it 'notifies each of several inbox members exactly once' do
      member_b = instance_double(User, id: 102)
      allow(inbox).to receive(:members).and_return([member, member_b, sender])

      described_class.new(message: message).perform

      expect(NotificationBuilder).to have_received(:new).with(hash_including(user: member)).once
      expect(NotificationBuilder).to have_received(:new).with(hash_including(user: member_b)).once
      expect(NotificationBuilder).not_to have_received(:new).with(hash_including(user: sender))
    end

    it 'does not notify inbox members when the conversation has an assignee' do
      allow(conversation).to receive(:assignee).and_return(assignee)
      allow(notifications_relation).to receive(:exists?).with(user: assignee, secondary_actor: message).and_return(false)
      allow(inbox).to receive(:members).and_return([member])

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new).with(hash_including(user: member))
    end

    it 'does not notify inbox members for a brand-new conversation (2-minute guard)' do
      allow(conversation).to receive(:created_at).and_return(30.seconds.ago)
      allow(inbox).to receive(:members).and_return([member])

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new)
    end

    it 'skips an inbox member already notified (e.g. as a participant or mention)' do
      allow(inbox).to receive(:members).and_return([member])
      allow(notified_relation).to receive(:pluck).with(:user_id).and_return([member.id])

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new).with(hash_including(user: member))
    end
  end
end
