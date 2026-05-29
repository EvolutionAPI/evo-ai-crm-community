module EvoFlow
  # Pure helpers used by BackfillContactEventsWorker — kept separate so the
  # mapping table and the SHA256 id derivation can be unit-tested without
  # spinning up the worker.
  class BackfillMapper
    # `source` names the producing subsystem (required by EvoFlow::EventSchema
    # for every conversation.* event), NOT the backfill itself — backfill
    # provenance lives in the `backfill|` message_id prefix below, a separate
    # axis. Backfilled events carry the same source the live producer would emit
    # (conversation.resolved matches the live ConversationEventsListener; the
    # reporting metrics name ReportingEventListener, their only producer). Both
    # follow the shared `*_management` convention (EVO-1570).
    CONVERSATION_SOURCE = 'conversation_management'.freeze
    REPORTING_SOURCE = 'reporting_management'.freeze

    # Single source of truth per legacy ReportingEvent#name: the canonical
    # EvoFlow event, its source, and how the row's `value`/timestamp land on the
    # event's schema optionals (EvoFlow::EventSchema). `value` is seconds for the
    # timing events; bot_* carry only a timestamp. `value_field`/`time_field` are
    # omitted when the schema has no home for them. Source of truth for the
    # legacy names is app/listeners/reporting_event_listener.rb.
    REPORTING_EVENTS = {
      'conversation_resolved' => {
        event: 'conversation.resolved', source: CONVERSATION_SOURCE,
        value_field: :resolution_time_seconds
      },
      'first_response' => {
        event: 'conversation.first_reply', source: REPORTING_SOURCE,
        value_field: :response_time_seconds, time_field: :replied_at, time_from: :event_end_time
      },
      'reply_time' => {
        event: 'conversation.reply_time', source: REPORTING_SOURCE,
        value_field: :reply_time_seconds, time_field: :measured_at, time_from: :event_end_time
      },
      'conversation_bot_handoff' => {
        event: 'conversation.bot_handoff', source: REPORTING_SOURCE,
        time_field: :handoff_at, time_from: :event_start_time
      },
      'conversation_bot_resolved' => {
        event: 'conversation.bot_resolved', source: REPORTING_SOURCE,
        time_field: :resolved_at, time_from: :event_end_time
      }
    }.transform_values(&:freeze).freeze

    # Fail loud (AC6): an unmapped ReportingEvent#name means the table above is
    # incomplete — surface it instead of silently dropping data on backfill.
    def self.reporting_event_descriptor(reporting_event)
      REPORTING_EVENTS[reporting_event.name.to_s] ||
        raise(EvoFlow::InvalidEventName, reporting_event.name.to_s)
    end

    # Deterministic backfill-namespaced id. The "backfill|" prefix makes
    # rollback (DELETE WHERE message_id LIKE 'backfill|%' on ClickHouse)
    # selective; the SHA256 keeps the id stable across reruns once
    # idempotency is wired downstream (evo-flow story 2.4).
    def self.message_id_for(source_type, source_id)
      Digest::SHA256.hexdigest("backfill|#{source_type}|#{source_id}")
    end
  end
end
