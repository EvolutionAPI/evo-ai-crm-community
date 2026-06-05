class Messages::NewMessageNotificationService
  pattr_initialize [:message!]

  NEW_CONVERSATION_NOTIFICATION_GUARD = 2.minutes

  def perform
    return unless message.notifiable?

    notify_conversation_assignee
    notify_participating_users
    notify_inbox_members_if_unassigned
  end

  private

  delegate :conversation, :sender, to: :message

  def notify_conversation_assignee
    return if conversation.assignee.blank?
    return if already_notified?(conversation.assignee)
    return if conversation.assignee == sender

    NotificationBuilder.new(
      notification_type: 'assigned_conversation_new_message',
      user: conversation.assignee,
      primary_actor: message.conversation,
      secondary_actor: message
    ).perform
  end

  def notify_participating_users
    participating_users = conversation.conversation_participants.map(&:user)
    participating_users -= [sender] if sender.is_a?(User)

    participating_users.uniq.each do |participant|
      next if already_notified?(participant)

      NotificationBuilder.new(
        notification_type: 'participating_conversation_new_message',
        user: participant,
        primary_actor: message.conversation,
        secondary_actor: message
      ).perform
    end
  end

  # An unassigned conversation is invisible to the team, so every inbox member
  # is notified of new activity. The 2-minute guard skips brand-new conversations
  # to avoid doubling up with the conversation_created notification.
  def notify_inbox_members_if_unassigned
    return if conversation.assignee.present?
    return if conversation.created_at > NEW_CONVERSATION_NOTIFICATION_GUARD.ago

    conversation.inbox.members.each do |member|
      next if member == sender
      next if notified_member_ids.include?(member.id)

      NotificationBuilder.new(
        notification_type: 'assigned_conversation_new_message',
        user: member,
        primary_actor: message.conversation,
        secondary_actor: message
      ).perform
    end
  end

  # Single query for the whole inbox fan-out instead of one exists? per member —
  # an unassigned inbox can have many members.
  def notified_member_ids
    @notified_member_ids ||= conversation.notifications.where(secondary_actor: message).pluck(:user_id)
  end

  # The user could already have been notified via a mention or via assignment
  # So we don't need to notify them again
  def already_notified?(user)
    conversation.notifications.exists?(user: user, secondary_actor: message)
  end
end
