# Register EvoFlow::* listeners for Wisper events emitted by Contact,
# Conversation, Message, and PipelineItem models. Mirrors the
# contact_company_listeners.rb pattern but uses `.new` (legacy EvoCampaign
# idiom) since EvoFlow listeners are not singletons.
#
# Intentionally NOT `to_prepare` — Wisper 2.0 does not deduplicate
# subscribers, so reloading the codebase under `to_prepare` would silently
# register additional listener instances in development.
Rails.application.config.after_initialize do
  Wisper.subscribe(EvoFlow::ContactEventsListener.new)
  Wisper.subscribe(EvoFlow::ConversationEventsListener.new)
  Wisper.subscribe(EvoFlow::MessageEventsListener.new)
  Wisper.subscribe(EvoFlow::PipelineEventsListener.new)

  # Eager-reference EventSchema so its boot-time sanity check (verifies every
  # EVENT_NAME has a DEFINITIONS entry) runs at startup, not lazily on the
  # first event publish. Without this Zeitwerk would only load EventSchema
  # when the first publisher calls into it — potentially hours after a deploy
  # that broke the EVENT_NAMES <-> DEFINITIONS sync.
  EvoFlow::EventSchema

  Rails.logger.info 'EvoFlow listeners registered (contact, conversation, message, pipeline)'
end
