module EvoFlow
  # Pure helpers used by BackfillContactEventsWorker — kept separate so the
  # mapping table and the SHA256 id derivation can be unit-tested without
  # spinning up the worker.
  class BackfillMapper
    # Legacy ReportingEvent#name -> canonical EvoFlow EVENT_NAMES entry.
    # Source of truth for the legacy values is app/listeners/reporting_event_listener.rb.
    REPORTING_EVENT_NAME_MAP = {
      'conversation_resolved' => 'conversation.resolved',
      'first_response' => 'conversation.first_reply',
      'reply_time' => 'conversation.reply_time',
      'conversation_bot_handoff' => 'conversation.bot_handoff',
      'conversation_bot_resolved' => 'conversation.bot_resolved'
    }.freeze

    def self.map_reporting_event_to_event_name(reporting_event)
      mapped = REPORTING_EVENT_NAME_MAP[reporting_event.name.to_s]
      # Fail loud (AC6): unmapped ReportingEvent#name means the table above is
      # incomplete — surface it instead of silently dropping data on backfill.
      raise EvoFlow::InvalidEventName, reporting_event.name.to_s if mapped.nil?

      mapped
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
