# Executes automation-rule actions for contact-triggered events
# (`contact_created` / `contact_updated`) that have no conversation in scope.
#
# Only a subset of actions can run without a conversation: webhooks and
# contact-level labels operate directly on the contact. Conversation-bound
# actions (send_message, assign_team, assign_agent, pipeline moves, status
# changes, …) cannot run here. Instead of silently doing nothing — the previous
# behaviour of `AutomationRuleListener#execute_contact_actions`, which only
# handled `send_webhook_event` and left everything else as a no-op — they are
# recorded on the run as `skipped` with a reason, so the outcome is observable
# in the automation logs (`automation_rule_runs`).
class AutomationRules::ContactActionService
  # EVO-1642: contact-level labels are the canonical implementations in the
  # shared module — included here so this executor stops hand-rolling its own
  # add_label/remove_label. `@contact` is set and `@conversation` is nil, so
  # they take the contact branch. `send_webhook_event` stays local because the
  # contact webhook event string is a live external contract (see below).
  include AutomationRules::ConversationActionHandlers

  # Actions that operate on the contact itself and need no conversation.
  CONTACT_NATIVE_ACTIONS = %w[send_webhook_event add_label remove_label update_custom_attribute].freeze

  def initialize(rule, contact, recorder: nil)
    @rule = rule
    @contact = contact
    @recorder = recorder
  end

  def perform
    # Tag downstream events as performed-by-automation so the listener's loop
    # guard (`performed_by_automation?`) skips them.
    Current.executed_by = @rule
    Array(@rule.actions).each { |action| run_action(action.with_indifferent_access) }
  ensure
    Current.reset
  end

  private

  def run_action(action)
    action_name = action[:action_name]
    action_params = action[:action_params]

    return record_skip(action_name) unless CONTACT_NATIVE_ACTIONS.include?(action_name)
    return record_skip(action_name) if action_name == 'update_custom_attribute' && !contact_scoped_attribute?(action_params)

    dispatch_native_action(action_name, action_params)
    @recorder&.add_step("Action: #{action_name}", level: 'success', data: { params: action_params })
  rescue StandardError => e
    Rails.logger.error "Automation Rule #{@rule.id}: Error executing contact action #{action_name}: #{e.message}"
    @recorder&.add_step("Action errored: #{action_name}", level: 'error', data: { error: "#{e.class}: #{e.message}" })
    EvolutionExceptionTracker.new(e).capture_exception
  end

  def record_skip(action_name)
    @recorder&.add_step(
      "Action skipped: #{action_name}",
      level: 'warn',
      data: {
        action_name: action_name,
        reason: 'requires a conversation; contact trigger has no conversation in scope'
      }
    )
  end

  # update_custom_attribute is contact-native ONLY for contact_attribute targets;
  # conversation/pipeline_item attributes need a conversation, so on a contact
  # trigger they would be a silent no-op — record them as skipped instead.
  def contact_scoped_attribute?(action_params)
    raw = Array(action_params).first
    raw.is_a?(Hash) && raw.with_indifferent_access[:custom_attribute_model].to_s == 'contact_attribute'
  end

  # The action_name is constrained to CONTACT_NATIVE_ACTIONS before we get here,
  # so no arbitrary method can be invoked.
  def dispatch_native_action(action_name, action_params)
    case action_name
    when 'send_webhook_event' then send_webhook_event(action_params)
    when 'add_label' then add_label(action_params)
    when 'remove_label' then remove_label(action_params)
    when 'update_custom_attribute' then update_custom_attribute(action_params)
    end
  end

  # Kept local (not delegated to the shared module): the contact webhook event
  # string is a LIVE external contract — integrations filter on
  # `contact_created`/`contact_updated`. Only the dormant flow executor was
  # unified to `automation_event.*` (EVO-1641 review). Also guards a blank URL.
  def send_webhook_event(action_params)
    webhook_url = action_params.is_a?(Array) ? action_params[0] : action_params
    return if webhook_url.blank?

    clean_url = webhook_url.to_s.strip
    # EVO-1641: the contact webhook string is a LIVE external contract
    # (integrations filter on `contact_created`/`contact_updated`), so it stays
    # as-is. Only the dormant flow executor was unified to `automation_event.*`.
    payload = (@contact.webhook_data || {}).merge(event: "contact_#{@rule.event_name.split('_').last}")
    WebhookJob.perform_later(clean_url, payload)
    Rails.logger.info "Automation Rule #{@rule.id}: Sent webhook to #{clean_url} for contact #{@contact.id}"
  end
end
