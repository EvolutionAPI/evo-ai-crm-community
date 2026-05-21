# frozen_string_literal: true

module EvoFlow
  # Subscribes to Wisper :conversation_created and :conversation_resolved
  # and forwards them to evo-flow as track events.
  #
  # Dual-shape note:
  # - `:conversation_created` is published *twice* by the Conversation model
  #   (Wisper direct via `publish(:conversation_created, data: {...})` and
  #    Dispatcher via `Rails.configuration.dispatcher.dispatch(...)`). The
  #   `return if data.respond_to?(:data)` guard de-dupes by rejecting the
  #   Dispatcher envelope (Events::Base has `.data`).
  # - `:conversation_resolved` is published *only* via Dispatcher (see
  #   `Conversation#notify_status_change`). The handler accepts the
  #   `Events::Base` shape and reads from `event.data`.
  #
  # `evo_flow_enabled?` is duplicated across the 4 EvoFlow listeners by
  # design (tech-spec §Technical Decisions #2: no shared base class).
  class ConversationEventsListener
    TRACK_PATH = '/events/track'

    def conversation_created(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      conversation = event_data[:conversation]
      unless conversation
        Rails.logger.error('EvoFlow::ConversationEventsListener#conversation_created: conversation is nil')
        return
      end
      return unless evo_flow_enabled?

      enqueue_created(conversation)
    rescue StandardError => e
      log_failure(__method__, e)
    end

    # AC2: receives Events::Base from SyncDispatcher (Conversation#notify_status_change
    # is the only producer). No Wisper-direct shape exists for this event.
    def conversation_resolved(event)
      return unless event.respond_to?(:data)

      event_data = event.data
      conversation = event_data[:conversation]
      unless conversation
        Rails.logger.error('EvoFlow::ConversationEventsListener#conversation_resolved: conversation is nil')
        return
      end
      return unless evo_flow_enabled?

      enqueue_resolved(conversation, event_data)
    rescue StandardError => e
      log_failure(__method__, e)
    end

    private

    def enqueue_created(conversation)
      event_name = 'conversation.created'
      source_event_uuid = "#{conversation.id}.#{conversation.created_at.to_i}"
      contact_id = conversation.contact_id
      message_id = EvoFlow::PayloadBuilder.message_id_for(event_name, contact_id, source_event_uuid)
      payload = EvoFlow::PayloadBuilder.build_track(
        event_name: event_name,
        contact_id: contact_id,
        properties: build_created_properties(conversation),
        occurred_at: conversation.created_at,
        message_id: message_id
      )
      EvoFlow::PublishEventWorker.perform_async(TRACK_PATH, JSON.parse(payload.to_json))
    end

    def enqueue_resolved(conversation, event_data)
      event_name = 'conversation.resolved'
      # Use updated_at (when status flipped to resolved) for idempotency.
      occurred_at = conversation.updated_at || Time.zone.now
      source_event_uuid = "#{conversation.id}.resolved.#{occurred_at.to_i}"
      contact_id = conversation.contact_id
      message_id = EvoFlow::PayloadBuilder.message_id_for(event_name, contact_id, source_event_uuid)
      payload = EvoFlow::PayloadBuilder.build_track(
        event_name: event_name,
        contact_id: contact_id,
        properties: build_resolved_properties(conversation, event_data),
        occurred_at: occurred_at,
        message_id: message_id
      )
      EvoFlow::PublishEventWorker.perform_async(TRACK_PATH, JSON.parse(payload.to_json))
    end

    def build_created_properties(conversation)
      inbox = conversation.inbox
      {
        conversation_id: conversation.id,
        inbox_id: conversation.inbox_id,
        inbox_name: inbox&.name,
        channel_type: inbox&.channel_type,
        source: 'conversation_management'
      }
    end

    def build_resolved_properties(conversation, event_data)
      inbox = conversation.inbox
      performed_by = event_data[:performed_by]
      {
        conversation_id: conversation.id,
        inbox_id: conversation.inbox_id,
        inbox_name: inbox&.name,
        channel_type: inbox&.channel_type,
        resolved_by_id: performed_by.respond_to?(:id) ? performed_by.id : performed_by,
        resolved_by_type: performed_by.respond_to?(:class) ? performed_by.class.name : nil,
        resolution_time_seconds: resolution_time_seconds(conversation),
        source: 'conversation_management'
      }.compact
    end

    def resolution_time_seconds(conversation)
      return nil unless conversation.created_at && conversation.updated_at

      (conversation.updated_at - conversation.created_at).to_i
    end

    def evo_flow_enabled?
      EvoFlow.enabled?
    end

    # F6/F8 mitigation: see ContactEventsListener#log_failure for rationale.
    def log_failure(handler, error)
      tag = enqueue_loss?(error) ? '[EvoFlow][enqueue-loss]' : '[EvoFlow]'
      Rails.logger.error(
        "#{tag} EvoFlow::ConversationEventsListener##{handler} failed: #{error.class}: #{error.message}"
      )
      Sentry.capture_exception(error) if defined?(Sentry)
      nil
    end

    def enqueue_loss?(error)
      return true if defined?(Redis::BaseConnectionError) && error.is_a?(Redis::BaseConnectionError)

      error.is_a?(ArgumentError) && error.message.include?('occurred_at is required')
    end
  end
end
