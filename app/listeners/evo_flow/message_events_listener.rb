# frozen_string_literal: true

module EvoFlow
  # Subscribes to Wisper :message_created and :message_status_changed and
  # forwards them to evo-flow as track events.
  #
  # `evo_flow_enabled?` is duplicated across the 4 EvoFlow listeners by
  # design (tech-spec §Technical Decisions #2: no shared base class).
  #
  # Hot-path note (F4): handler fires per inbound message. The
  # `message.conversation.inbox` access can incur 2 extra SQL reads if the
  # caller hasn't preloaded the association. Bulk paths SHOULD preload
  # `conversation: :inbox`; the listener does not preload defensively.
  #
  # M5 filter: only `incoming` and `outgoing` messages are tracked.
  # `activity` (system events) and `template` (CSAT/whatsapp template
  # broadcasts) are intentionally excluded — they would flood the hot
  # path with noise that has no analytics value.
  class MessageEventsListener
    TRACK_PATH = '/events/track'
    TRACKED_MESSAGE_TYPES = %w[incoming outgoing].freeze
    # AC3: previous_status → canonical event_name mapping.
    # Anything outside this map is dropped (logged as warn) to avoid
    # shipping non-canonical event names.
    STATUS_TRANSITION_EVENT_NAMES = {
      'sent' => 'message.delivered',
      'delivered' => 'message.read'
    }.freeze
    FAILED_EVENT_NAME = 'message.failed'

    def message_created(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      message = event_data[:message]
      return log_missing_message unless message
      return unless evo_flow_enabled?
      return unless tracked_type?(message)

      inbox = inbox_for(message)
      return warn_inbox_missing(message) unless inbox

      enqueue_created(message, inbox)
    rescue StandardError => e
      log_failure(__method__, e)
    end

    # AC3: maps Wisper :message_status_changed to message.delivered /
    # message.read / message.failed based on the (previous_status, status)
    # transition. Producer is `Messages::StatusUpdateService` (see
    # `publish(:message_status_changed, ...)`).
    def message_status_changed(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      message = event_data[:message]
      return log_missing_message unless message
      return unless evo_flow_enabled?

      event_name = resolve_status_event_name(event_data[:previous_status], event_data[:status])
      return warn_unmapped_status(message, event_data) unless event_name

      inbox = inbox_for(message)
      return warn_inbox_missing(message) unless inbox

      enqueue_status_change(message, inbox, event_name, event_data)
    rescue StandardError => e
      log_failure(__method__, e)
    end

    private

    def tracked_type?(message)
      TRACKED_MESSAGE_TYPES.include?(message.message_type.to_s)
    end

    def resolve_status_event_name(previous_status, status)
      return FAILED_EVENT_NAME if status.to_s == 'failed'

      STATUS_TRANSITION_EVENT_NAMES[previous_status.to_s]
    end

    def inbox_for(message)
      message.conversation&.inbox
    end

    def log_missing_message
      Rails.logger.error('EvoFlow::MessageEventsListener: message is nil')
      nil
    end

    def warn_inbox_missing(message)
      Rails.logger.warn(
        "EvoFlow::MessageEventsListener: inbox missing for message #{message.id}"
      )
      nil
    end

    def warn_unmapped_status(message, event_data)
      Rails.logger.warn(
        "EvoFlow::MessageEventsListener#message_status_changed: unmapped " \
        "transition #{event_data[:previous_status]} → #{event_data[:status]} " \
        "for message #{message.id}"
      )
      nil
    end

    def enqueue_created(message, inbox)
      event_name = 'message.created'
      source_event_uuid = "#{message.id}.#{message.created_at.to_i}"
      contact_id = message.conversation.contact_id
      message_id = EvoFlow::PayloadBuilder.message_id_for(event_name, contact_id, source_event_uuid)
      payload = EvoFlow::PayloadBuilder.build_track(
        event_name: event_name,
        contact_id: contact_id,
        properties: build_created_properties(message, inbox),
        occurred_at: message.created_at,
        message_id: message_id
      )
      EvoFlow::PublishEventWorker.perform_async(TRACK_PATH, JSON.parse(payload.to_json), current_tenant_id)
    end

    def enqueue_status_change(message, inbox, event_name, event_data)
      occurred_at = message.updated_at || Time.zone.now
      # Idempotency: include event_name + occurred_at so multiple status
      # transitions on the same message produce distinct messageIds.
      source_event_uuid = "#{message.id}.#{event_name}.#{occurred_at.to_i}"
      contact_id = message.conversation.contact_id
      message_id = EvoFlow::PayloadBuilder.message_id_for(event_name, contact_id, source_event_uuid)
      payload = EvoFlow::PayloadBuilder.build_track(
        event_name: event_name,
        contact_id: contact_id,
        properties: build_status_properties(message, inbox, event_data),
        occurred_at: occurred_at,
        message_id: message_id
      )
      EvoFlow::PublishEventWorker.perform_async(TRACK_PATH, JSON.parse(payload.to_json), current_tenant_id)
    end

    # PII/volume guard: `content` is truncated (default 2000 chars) and can be
    # disabled entirely via `EVO_FLOW_MESSAGE_CONTENT_DISABLED=true`. The worker
    # already redacts `properties` for Sidekiq args/failure broadcasts; this is
    # an additional pre-enqueue cap to bound payload size and reduce PII exposure
    # in-flight to evo-flow.
    DEFAULT_CONTENT_MAX_LENGTH = 2000

    def build_created_properties(message, inbox)
      # `.compact` is intentional: when `EVO_FLOW_MESSAGE_CONTENT_DISABLED=true`
      # `sanitized_content` returns nil and we omit the `content` key entirely
      # rather than emit `content: null` downstream. Other keys here are always
      # present, so the compact does not silently drop unrelated data today —
      # tighten to a targeted `delete(:content) if ...` if more nullable keys
      # are added in the future.
      {
        message_id: message.id,
        conversation_id: message.conversation_id,
        message_type: message.message_type,
        content_type: message.content_type,
        content: sanitized_content(message.content),
        channel_type: inbox.channel_type,
        source: 'messaging'
      }.compact
    end

    # Truncation cap is by CHARACTER count, not byte count. Multibyte payloads
    # (emoji, CJK) may exceed `max * 1` bytes; the cap is meant to bound payload
    # size loosely, not enforce a strict byte ceiling. If downstream evo-flow
    # gains a hard byte limit, switch to `bytesize` here.
    def sanitized_content(content)
      return nil if content.nil?
      return nil if ENV['EVO_FLOW_MESSAGE_CONTENT_DISABLED'].to_s.downcase == 'true'

      max = (ENV['EVO_FLOW_MESSAGE_CONTENT_MAX_LENGTH'].presence || DEFAULT_CONTENT_MAX_LENGTH).to_i
      max = DEFAULT_CONTENT_MAX_LENGTH if max <= 0

      content.length > max ? "#{content[0, max]}…[truncated]" : content
    end

    def build_status_properties(message, inbox, event_data)
      {
        message_id: message.id,
        conversation_id: message.conversation_id,
        message_type: message.message_type,
        channel_type: inbox.channel_type,
        previous_status: event_data[:previous_status],
        status: event_data[:status],
        external_error: event_data[:external_error],
        source: 'messaging'
      }.compact
    end

    def evo_flow_enabled?
      EvoFlow.enabled?
    end

    # F6/F8 mitigation: see ContactEventsListener#log_failure for rationale.
    def log_failure(handler, error)
      tag = enqueue_loss?(error) ? '[EvoFlow][enqueue-loss]' : '[EvoFlow]'
      Rails.logger.error(
        "#{tag} EvoFlow::MessageEventsListener##{handler} failed: #{error.class}: #{error.message}"
      )
      Sentry.capture_exception(error) if defined?(Sentry)
      nil
    end

    def enqueue_loss?(error)
      return true if defined?(Redis::BaseConnectionError) && error.is_a?(Redis::BaseConnectionError)

      error.is_a?(ArgumentError) && error.message.include?('occurred_at is required')
    end

    # Multi-tenant deployments fill the runtime-context extension point with the
    # tenant bound to the CURRENT process (request or job); the id is serialized
    # into the job args so the publish carries X-Evo-Tenant-Id. Community
    # single-tenant: the default impl answers nil and nothing is sent.
    def current_tenant_id
      EvoExtensionPoints::RuntimeContext.current_scope_id
    end
  end
end
