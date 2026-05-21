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

  Rails.logger.info 'EvoFlow listeners registered (contact, conversation, message, pipeline)'
end
