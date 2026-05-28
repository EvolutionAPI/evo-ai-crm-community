# frozen_string_literal: true

# NotificationSerializer - Optimized serialization for Notification resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   NotificationSerializer.serialize(@notification)
#
module NotificationSerializer
  extend self

  # Serialize single Notification
  #
  # @param notification [Notification] Notification to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_actors Include primary and secondary actors
  #
  # @return [Hash] Serialized notification ready for Oj
  #
  def serialize(notification, include_actors: true)
    result = {
      id: notification.id,
      notification_type: notification.notification_type,
      primary_actor_type: notification.primary_actor_type,
      primary_actor_id: notification.primary_actor_id,
      secondary_actor_type: notification.secondary_actor_type,
      secondary_actor_id: notification.secondary_actor_id,
      read_at: notification.read_at&.to_i,
      created_at: notification.created_at.to_i,
      updated_at: notification.updated_at.to_i,
      last_activity_at: notification.last_activity_at&.iso8601,
      push_message_title: notification.push_message_title,
      push_message_body: notification.push_message_body
    }

    if include_actors
      if notification.primary_actor.present?
        result[:primary_actor] = serialize_actor(notification.primary_actor)
      end

      if notification.secondary_actor.present?
        result[:secondary_actor] = serialize_actor(notification.secondary_actor)
      end

      sender = notification_sender(notification)
      if sender.present?
        result[:sender] = {
          id: sender.id,
          name: sender.name,
          avatar_url: sender.try(:avatar_url),
          type: sender.class.name
        }
      end
    end

    result
  end

  # Serialize collection of Notifications
  #
  # @param notifications [Array<Notification>, ActiveRecord::Relation]
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized notifications
  #
  def serialize_collection(notifications, **options)
    return [] unless notifications

    arr = Array(notifications)
    preload_message_senders(arr)
    preload_conversation_contacts(arr)
    preload_conversation_inboxes(arr)
    arr.map { |notification| serialize(notification, **options) }
  end

  private

  def preload_message_senders(notifications)
    messages = notifications.filter_map do |n|
      n.secondary_actor if n.secondary_actor_type == 'Message' && n.secondary_actor.present?
    end
    return if messages.empty?

    ActiveRecord::Associations::Preloader.new(records: messages, associations: [:sender]).call
  end

  def preload_conversation_contacts(notifications)
    conversations = notifications.filter_map do |n|
      n.primary_actor if n.primary_actor.is_a?(Conversation)
    end
    return if conversations.empty?

    ActiveRecord::Associations::Preloader.new(records: conversations, associations: [:contact]).call
  rescue StandardError => e
    Rails.logger.error("[NotificationSerializer] preload_conversation_contacts failed: #{e.class} - #{e.message}")
  end

  def preload_conversation_inboxes(notifications)
    conversations = notifications.filter_map do |n|
      n.primary_actor if n.primary_actor.is_a?(Conversation)
    end
    return if conversations.empty?

    ActiveRecord::Associations::Preloader.new(records: conversations, associations: [:inbox]).call
  rescue StandardError => e
    Rails.logger.error("[NotificationSerializer] preload_conversation_inboxes failed: #{e.class} - #{e.message}")
  end

  # Delegates to Notification#notification_sender — single source of truth.
  # conversation_creation/assignment: accepted N+1 for both push_message_body and sender
  # (scoped message queries bypass AR caches; preloading all messages would be expensive).
  def notification_sender(notification)
    notification.notification_sender
  end

  # Serialize polymorphic actor
  def serialize_actor(actor)
    case actor
    when User
      UserSerializer.serialize(actor)
    when Contact
      { id: actor.id, name: actor.name, avatar_url: actor.avatar_url, type: 'Contact' }
    when Conversation
      data = { id: actor.id, display_id: actor.display_id, type: 'Conversation' }
      begin
        contact = actor.contact
        if contact.present?
          data[:contact] = { id: contact.id, name: contact.name, avatar_url: contact.avatar_url }
        end
      rescue StandardError => e
        Rails.logger.error("[NotificationSerializer] serialize contact failed for conversation #{actor.id}: #{e.class} - #{e.message}")
      end
      begin
        inbox = actor.inbox
        data[:channel] = inbox.channel_type if inbox&.channel_type.present?
      rescue StandardError => e
        Rails.logger.error("[NotificationSerializer] serialize inbox failed for conversation #{actor.id}: #{e.class} - #{e.message}")
      end
      data
    when Message
      sender = actor.sender
      data = { id: actor.id, content: actor.content&.truncate(50), type: 'Message' }
      data[:sender] = { id: sender.id, name: sender.name, avatar_url: sender.try(:avatar_url), type: sender.class.name } if sender.present?
      data
    else
      { id: actor.id, type: actor.class.name }
    end
  end
end
