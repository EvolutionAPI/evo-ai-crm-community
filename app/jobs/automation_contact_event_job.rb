# Feeds contact_created / contact_updated events to the automation engine ONLY.
#
# Contact#dispatch_create_event / #dispatch_update_event (the full sync+async
# dispatcher path) are intentionally disabled — contacts publish through Wisper
# (EvoFlow) for integrations. That left AutomationRuleListener, which subscribes
# to the AsyncDispatcher, with no source of contact events, so contact-triggered
# automation rules never ran.
#
# We deliberately do NOT re-enable the broad dispatch: that would also resurrect
# the legacy HookListener / WebhookListener / ActionCableListener for contacts
# and double the outbound webhooks already sent via EvoFlow. Instead this job
# invokes the automation listener directly, in the background, for contacts only.
class AutomationContactEventJob < ApplicationJob
  queue_as :critical

  SUPPORTED_EVENTS = %w[contact_created contact_updated].freeze

  def perform(event_name, contact_id, changed_attributes = {})
    return unless SUPPORTED_EVENTS.include?(event_name)

    contact = Contact.find_by(id: contact_id)
    return if contact.nil?

    event = Events::Base.new(event_name, Time.zone.now, { contact: contact, changed_attributes: changed_attributes })
    AutomationRuleListener.instance.public_send(event_name, event)
  end
end
