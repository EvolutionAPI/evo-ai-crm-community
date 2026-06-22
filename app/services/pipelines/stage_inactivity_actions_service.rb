require 'digest'

# Time-based evaluator for stage inactivity rules. Mirrors
# AgentBots::InactivityActionsService but operates per pipeline_item and per
# rule (not a per-index ladder), and reserves the execution row BEFORE sending
# to make external sends idempotent under Sidekiq retries / concurrent
# schedulers (finding #1).
class Pipelines::StageInactivityActionsService
  include Pipelines::StageMessageActions

  INACTIVITY_TRIGGER = 'inactivity'.freeze

  def initialize(pipeline_item)
    @pipeline_item = pipeline_item
  end

  def process
    return unless eligible?

    inactivity_rules.each do |rule|
      evaluate_rule(rule)
    rescue StandardError => e
      Rails.logger.error "[StageInactivity] item=#{@pipeline_item.id} rule failed: #{e.message}"
    end
  end

  private

  def eligible?
    return false if @pipeline_item.completed_at.present?
    return false if @pipeline_item.pipeline_stage.nil?

    inactivity_rules.any?
  end

  def inactivity_rules
    @inactivity_rules ||= begin
      rules = @pipeline_item.pipeline_stage.automation_rules&.dig('rules') || []
      rules.map(&:with_indifferent_access).select { |r| r[:trigger] == INACTIVITY_TRIGGER }
    end
  end

  def evaluate_rule(rule)
    rule_id = rule_id_for(rule)
    return if StageInactivityExecution.executed?(@pipeline_item.id, rule_id)

    base    = inactivity_base(rule)
    minutes = inactivity_minutes(rule)
    elapsed = elapsed_minutes(base)
    return if elapsed.nil? || elapsed < minutes

    fire(rule, rule_id, base)
  end

  # --- timing ---------------------------------------------------------------

  def inactivity_base(rule)
    rule.dig(:trigger_value, :base) || 'no_customer_reply'
  end

  def inactivity_minutes(rule)
    rule.dig(:trigger_value, :minutes).to_i
  end

  # Returns elapsed minutes for the base, or nil when the rule is a no-op for
  # this item (e.g. no_customer_reply on a lead with no conversation).
  def elapsed_minutes(base)
    case base
    when 'stage_stagnation'
      seconds_since(stage_entered_at)
    when 'no_customer_reply'
      at = last_incoming_at
      at.nil? ? nil : seconds_since(at)
    end
  end

  def seconds_since(time)
    return nil if time.nil?

    ((Time.current - time) / 60.0).floor
  end

  # Time the item entered its CURRENT stage — not entered_at (which is
  # pipeline-scoped). Mirrors PipelineItem#days_in_current_stage.
  def stage_entered_at
    last_movement =
      if @pipeline_item.stage_movements.loaded?
        @pipeline_item.stage_movements.max_by(&:created_at)
      else
        @pipeline_item.stage_movements.order(:created_at).last
      end
    last_movement&.created_at || @pipeline_item.entered_at
  end

  def last_incoming_at
    conversation = @pipeline_item.conversation
    return nil if conversation.nil?

    conversation.messages.incoming.order(created_at: :desc).limit(1).pick(:created_at)
  end

  # --- idempotency key ------------------------------------------------------

  def rule_id_for(rule)
    rule[:id].presence || Digest::SHA1.hexdigest(
      [rule[:trigger], inactivity_base(rule), inactivity_minutes(rule), rule[:action], rule[:action_value]].join(':')
    )
  end

  # --- firing (reserve-before-send) ----------------------------------------

  def fire(rule, rule_id, base)
    target = Pipelines::StageInactivityTargetResolver.new(@pipeline_item).resolve(rule[:action])
    return if target.nil?

    execution = reserve(rule, rule_id, base)
    return if execution.nil? # lost the race — another worker already reserved

    message = dispatch(rule, target)
    execution.update(message_sent: message_text(rule, message))
  rescue StandardError => e
    Rails.logger.error "[StageInactivity] item=#{@pipeline_item.id} fire failed: #{e.message}"
  end

  # Reserve the unique (pipeline_item_id, rule_id) row before sending. If a
  # concurrent worker/retry already inserted it, RecordNotUnique => skip send.
  def reserve(rule, rule_id, base)
    StageInactivityExecution.create!(
      pipeline_item_id: @pipeline_item.id,
      pipeline_stage_id: @pipeline_item.pipeline_stage_id,
      rule_id: rule_id,
      base: base,
      action: rule[:action],
      action_config: rule,
      executed_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info "[StageInactivity] item=#{@pipeline_item.id} rule=#{rule_id} already reserved, skipping send"
    nil
  end

  def dispatch(rule, target)
    conversation = target.conversation
    case rule[:action]
    when 'send_ai_message'
      send_ai_message(conversation, suggested_message: rule[:ai_message])
    when 'send_direct_message'
      send_direct_message(conversation, rule[:action_value])
    when 'send_template'
      send_template(conversation, template_params_for(rule))
    when 'finalize'
      finalize(conversation, rule[:action_value])
    else
      Rails.logger.warn "[StageInactivity] unsupported inactivity action: #{rule[:action]}"
    end
  end

  def template_params_for(rule)
    { id: rule[:action_value] }
  end

  def message_text(rule, _dispatch_result)
    rule[:ai_message].presence || rule[:action_value].presence
  end
end
