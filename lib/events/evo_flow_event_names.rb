module EvoFlow
  # Canonical list of event names CRM emits to evo-flow.
  # Dot-notation matches the Events::Types convention (lib/events/types.rb).
  EVENT_NAMES = %w[
    contact.created contact.updated contact.deleted
    contact.label.added contact.label.removed contact.custom_attribute.changed
    conversation.created conversation.resolved
    conversation.activity conversation.first_reply conversation.reply_time
    conversation.bot_handoff conversation.bot_resolved
    message.created message.delivered message.read message.failed
    campaign.triggered campaign.message.sent campaign.message.opened campaign.message.clicked
    custom
  ].freeze

  # Feature gate. Primary ENV is `EVO_FLOW_ENABLED`; legacy
  # `AUTH_APIKEY_INTEGRATION_LOCAL` is honoured as a fallback during the
  # rollout transition (review L4) so existing deploys keep working. Drop
  # the legacy var once the rollout settles.
  def self.enabled?
    return ENV['EVO_FLOW_ENABLED'].to_s.casecmp('true').zero? if ENV['EVO_FLOW_ENABLED'].present?

    ENV['AUTH_APIKEY_INTEGRATION_LOCAL'].present?
  end
end
