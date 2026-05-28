# == Schema Information
#
# Table name: notifications
#
#  id                   :uuid             not null, primary key
#  last_activity_at     :datetime
#  meta                 :jsonb
#  notification_type    :integer          not null
#  primary_actor_type   :string           not null
#  read_at              :datetime
#  secondary_actor_type :string
#  snoozed_until        :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  primary_actor_id     :uuid             not null
#  secondary_actor_id   :uuid
#  user_id              :uuid             not null
#
# Indexes
#
#  index_notifications_on_user_id                  (user_id)
#  uniq_primary_actor_per_account_notifications    (primary_actor_type,primary_actor_id)
#  uniq_secondary_actor_per_account_notifications  (secondary_actor_type,secondary_actor_id)
#
class Notification < ApplicationRecord
  include MessageFormatHelper
  belongs_to :user

  belongs_to :primary_actor, polymorphic: true
  belongs_to :secondary_actor, polymorphic: true, optional: true

  NOTIFICATION_TYPES = {
    conversation_creation: 1,
    conversation_assignment: 2,
    assigned_conversation_new_message: 3,
    conversation_mention: 4,
    participating_conversation_new_message: 5,
    pipeline_task_assigned: 20,
    pipeline_task_due_soon: 21,
    pipeline_task_overdue: 22,
    pipeline_task_completed: 23
  }.freeze

  enum notification_type: NOTIFICATION_TYPES

  before_create :set_last_activity_at
  after_create_commit :process_notification_delivery, :dispatch_create_event
  after_destroy_commit :dispatch_destroy_event
  after_update_commit :dispatch_update_event

  PRIMARY_ACTORS = ['Conversation'].freeze

  def push_event_data
    # Secondary actor could be nil for cases like system assigning conversation
    payload = {
      id: id,
      notification_type: notification_type,
      primary_actor_type: primary_actor_type,
      primary_actor_id: primary_actor_id,
      read_at: read_at,
      secondary_actor: secondary_actor&.push_event_data,
      user: user&.push_event_data,
      created_at: created_at.to_i,
      last_activity_at: last_activity_at.to_i,
      snoozed_until: snoozed_until,
      meta: meta
    }
    payload.merge!(primary_actor_data) if primary_actor.present?
    payload
  end

  def fcm_push_data
    {
      id: id,
      notification_type: notification_type,
      primary_actor_id: primary_actor_id,
      primary_actor_type: primary_actor_type,
      primary_actor: primary_actor.push_event_data.with_indifferent_access.slice('conversation_id', 'id')
    }
  end

  # rubocop:disable Metrics/MethodLength
  def push_message_title
    notification_title_map = {
      'conversation_creation' => 'notifications.notification_title.conversation_creation',
      'conversation_assignment' => 'notifications.notification_title.conversation_assignment',
      'assigned_conversation_new_message' => 'notifications.notification_title.assigned_conversation_new_message',
      'participating_conversation_new_message' => 'notifications.notification_title.assigned_conversation_new_message',
      'conversation_mention' => 'notifications.notification_title.conversation_mention'
    }

    i18n_key = notification_title_map[notification_type]
    return '' unless i18n_key

    # Handle cases where conversation or primary_actor might be nil
    return '' unless conversation&.respond_to?(:display_id)

    if notification_type == 'conversation_creation'
      return '' unless primary_actor&.respond_to?(:inbox) && primary_actor.inbox&.respond_to?(:name)
      I18n.t(i18n_key, display_id: conversation.display_id, inbox_name: primary_actor.inbox.name)
    elsif %w[conversation_assignment assigned_conversation_new_message participating_conversation_new_message
             conversation_mention].include?(notification_type)
      I18n.t(i18n_key, display_id: conversation.display_id)
    else
      return '' unless primary_actor&.respond_to?(:display_id)
      I18n.t(i18n_key, display_id: primary_actor.display_id)
    end
  end
  # rubocop:enable Metrics/MethodLength

  # conversation_creation and conversation_assignment use scoped message queries
  # (.incoming, .outgoing) that bypass association caches — known N+1 per those types.
  def push_message_body
    case notification_type
    when 'conversation_creation', 'sla_missed_first_response'
      return '' unless conversation&.respond_to?(:messages)
      message_body(conversation.messages.first)
    when 'assigned_conversation_new_message', 'participating_conversation_new_message', 'conversation_mention'
      message_body(secondary_actor)
    when 'conversation_assignment'
      return '' unless conversation&.respond_to?(:messages)
      message_body((conversation.messages.incoming.last || conversation.messages.outgoing.last))
    else
      ''
    end
  end

  def conversation
    primary_actor
  end

  # Returns the sender (Contact or User) for this notification regardless of type.
  # Used by both the REST serializer and push_event_data so the logic lives in one place.
  def notification_sender
    case notification_type
    when 'assigned_conversation_new_message', 'participating_conversation_new_message', 'conversation_mention'
      secondary_actor.try(:sender)
    when 'conversation_creation'
      conversation&.messages&.first&.sender
    when 'conversation_assignment'
      # Sender for assignment events needs a product decision (assigner vs assignee);
      # the last message author is misleading. Out of scope here — return nil so the
      # REST/WS payload omits sender and the UI falls back to the conversation contact.
      nil
    when 'pipeline_task_assigned', 'pipeline_task_due_soon', 'pipeline_task_overdue', 'pipeline_task_completed'
      nil # task events have no message actor; title/preview/sender not in scope for this iteration
    end
  end

  private

  def message_body(actor)
    sender_name = sender_name(actor)
    content = message_content(actor)
    sender_name.present? ? "#{sender_name}: #{content}" : content
  end

  def sender_name(actor)
    actor.try(:sender)&.name || ''
  end

  def message_content(actor)
    content = actor.try(:content)
    attachments = actor.try(:attachments)

    if content.present?
      transform_user_mention_content(content.truncate(40))
    else
      attachments.present? ? I18n.t('notifications.attachment') : I18n.t('notifications.no_content')
    end
  end

  def process_notification_delivery
    push_subscribed = user_subscribed_to_notification?('push')
    email_subscribed = user_subscribed_to_notification?('email')

    Rails.logger.info("📱 [NOTIFICATION] Processing delivery for notification #{id}, type: #{notification_type}, user: #{user&.email}, push_subscribed: #{push_subscribed}, email_subscribed: #{email_subscribed}")

    if push_subscribed
      Rails.logger.info("📱 [NOTIFICATION] Enqueuing push notification job for notification #{id}")
      Notification::PushNotificationJob.perform_later(self)
    else
      Rails.logger.info("📱 [NOTIFICATION] Skipping push notification job - user not subscribed to push for #{notification_type}")
    end

    # Should we do something about the case where user subscribed to both push and email ?
    # In future, we could probably add condition here to enqueue the job for 30 seconds later
    # when push enabled and then check in email job whether notification has been read already.
    Notification::EmailNotificationJob.perform_later(self) if email_subscribed

    Notification::RemoveDuplicateNotificationJob.perform_later(self)
  end

  def user_subscribed_to_notification?(delivery_type)
    notification_setting = user.notification_settings.first
    return false if notification_setting.blank?

    # Check if the user has subscribed to the specified type of notification
    notification_setting.public_send("#{delivery_type}_#{notification_type}?")
  end

  def dispatch_create_event
    Rails.configuration.dispatcher.dispatch(NOTIFICATION_CREATED, Time.zone.now, notification: self)
  end

  def dispatch_update_event
    Rails.configuration.dispatcher.dispatch(NOTIFICATION_UPDATED, Time.zone.now, notification: self)
  end

  def dispatch_destroy_event
    Rails.configuration.dispatcher.dispatch(NOTIFICATION_DELETED, Time.zone.now, notification: self)
  end

  def set_last_activity_at
    self.last_activity_at = created_at
  end

  def primary_actor_data
    data = {
      primary_actor: primary_actor&.push_event_data,
      # TODO: Rename push_message_title to push_message_body
      push_message_title: push_message_body,
      push_message_body: push_message_body
    }
    s = notification_sender
    data[:sender] = { id: s.id, name: s.name, avatar_url: s.try(:avatar_url), type: s.class.name } if s.present?
    data
  end
end
