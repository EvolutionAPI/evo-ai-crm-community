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
  # Actions that operate on the contact itself and need no conversation.
  CONTACT_NATIVE_ACTIONS = %w[send_webhook_event add_label remove_label].freeze

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

  # The action_name is constrained to CONTACT_NATIVE_ACTIONS before we get here,
  # so no arbitrary method can be invoked.
  def dispatch_native_action(action_name, action_params)
    case action_name
    when 'send_webhook_event' then send_webhook_event(action_params)
    when 'add_label' then add_label(action_params)
    when 'remove_label' then remove_label(action_params)
    end
  end

  def send_webhook_event(action_params)
    webhook_url = action_params.is_a?(Array) ? action_params[0] : action_params
    return if webhook_url.blank?

    clean_url = webhook_url.to_s.strip
    payload = (@contact.webhook_data || {}).merge(event: "contact_#{@rule.event_name.split('_').last}")
    WebhookJob.perform_later(clean_url, payload)
    Rails.logger.info "Automation Rule #{@rule.id}: Sent webhook to #{clean_url} for contact #{@contact.id}"
  end

  def add_label(label_ids)
    labels = Label.where(id: label_ids)
    return if labels.empty?

    # Route through the setter so `saved_change_to_label_list?` dirty-tracks the
    # change and Contact#publish_label_changes fires (mirrors FlowExecutionService).
    titles = labels.pluck(:title)
    @contact.update!(label_list: (@contact.label_list + titles).uniq)
    Rails.logger.info "Automation Rule #{@rule.id}: Added #{labels.count} labels to contact #{@contact.id}"
  end

  def remove_label(label_ids)
    labels = Label.where(id: label_ids)
    return if labels.empty?

    titles = labels.pluck(:title)
    @contact.update!(label_list: @contact.label_list - titles)
    Rails.logger.info "Automation Rule #{@rule.id}: Removed #{labels.count} labels from contact #{@contact.id}"
  end
end
