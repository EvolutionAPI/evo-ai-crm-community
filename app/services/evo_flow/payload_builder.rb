module EvoFlow
  # Shapes the real evo-flow DTOs (camelCase, single-tenant: NO accountId).
  # track  -> TrackEventDto    (uses `event`)
  # identify -> IdentifyEventDto (uses `eventName`)
  # See evo-flow/src/modules/events/dto/*.
  #
  # InvalidEventName lives in app/services/evo_flow/invalid_event_name.rb
  # (its constructor formats the full "Unknown EvoFlow event_name: …" message
  # including the allowed list, so callers here just pass the bad value).
  class PayloadBuilder
    # Exactly 5 kwargs (RuboCop ParameterLists max 5 — do not add a 6th).
    def self.build_track(event_name:, contact_id:, properties:, occurred_at:, message_id:)
      validate_event_name!(event_name)
      {
        messageId: message_id,
        contactId: contact_id.to_s,
        event: event_name,
        properties: properties || {},
        timestamp: iso8601(occurred_at)
      }
    end

    def self.build_identify(event_name:, contact_id:, traits:, occurred_at:, message_id:)
      validate_event_name!(event_name)
      {
        messageId: message_id,
        contactId: contact_id.to_s,
        eventName: event_name,
        traits: traits || {},
        timestamp: iso8601(occurred_at)
      }
    end

    # AC6: raise on event_name outside EvoFlow::EVENT_NAMES.
    # Caught in CI (specs) and in production by PublishEventWorker
    # (rescued as an F4 exception — logged + dropped, not retried, since
    # an invalid name is a code bug and retries won't fix it).
    # The single source of truth for the canonical list is
    # lib/events/evo_flow_event_names.rb (EvoFlow::EVENT_NAMES).
    def self.validate_event_name!(event_name)
      return if EvoFlow::EVENT_NAMES.include?(event_name)

      raise EvoFlow::InvalidEventName, event_name
    end
    private_class_method :validate_event_name!

    # Deterministic, forward-looking idempotency key. NOTE: evo-flow has no
    # consumer-side dedup yet (clickhouse contact_events is MergeTree); Sidekiq
    # retries currently still duplicate downstream. Tracked separately.
    def self.message_id_for(event_name, contact_id, source_event_uuid)
      Digest::SHA256.hexdigest("#{event_name}|#{contact_id}|#{source_event_uuid}")
    end

    # Always emits UTC ISO-8601. A String is validated by re-parsing (fail
    # fast with ArgumentError rather than shipping an unparseable timestamp
    # that evo-flow would silently misread/reject downstream). nil is also
    # rejected — the caller must be explicit about the event timestamp so a
    # missing occurred_at never silently becomes "now".
    def self.iso8601(time)
      raise ArgumentError, 'occurred_at is required (no implicit Time.current fallback)' if time.nil?
      return Time.iso8601(time).utc.iso8601 if time.is_a?(String)

      time.utc.iso8601
    end
  end
end
