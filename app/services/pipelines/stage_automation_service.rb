class Pipelines::StageAutomationService
  include Pipelines::StageMessageActions

  # `inactivity` is accepted at save-time (controller validates against this
  # list) but is NOT fired here — it is time-based and handled by
  # Pipelines::StageInactivityActionsService. The event path skips it.
  SUPPORTED_TRIGGERS = %w[label_added conversation_status_changed custom_attribute_updated inactivity].freeze
  SUPPORTED_ACTIONS  = %w[
    move_to_stage move_to_pipeline assign_agent apply_label
    send_ai_message send_direct_message send_template finalize
  ].freeze
  INACTIVITY_TRIGGER = 'inactivity'.freeze

  def initialize(conversation, changed_attributes = {})
    @conversation       = conversation
    @changed_attributes = changed_attributes.with_indifferent_access
  end

  def perform
    Current.executed_by = :stage_automation
    @conversation.pipeline_items.includes(pipeline_stage: :pipeline).each do |pipeline_item|
      evaluate_stage_rules(pipeline_item)
    end
  ensure
    Current.reset
  end

  private

  def evaluate_stage_rules(pipeline_item)
    rules = pipeline_item.pipeline_stage.automation_rules&.dig('rules')
    return if rules.blank?

    rules.each do |rule|
      rule = rule.with_indifferent_access
      next unless SUPPORTED_TRIGGERS.include?(rule[:trigger])
      next if rule[:trigger] == INACTIVITY_TRIGGER # time-based; fired elsewhere
      next unless rule_matches?(rule)

      execute_action(rule, pipeline_item)
    end
  end

  def rule_matches?(rule)
    case rule[:trigger]
    when 'label_added'
      label_added_match?(rule[:trigger_value])
    when 'conversation_status_changed'
      status_changed_to_match?(rule[:trigger_value])
    when 'custom_attribute_updated'
      @changed_attributes.key?('custom_attributes')
    else
      false
    end
  end

  def label_added_match?(trigger_value)
    return false unless @changed_attributes.key?('label_list')

    old_labels, new_labels = @changed_attributes['label_list']
    added = Array(new_labels) - Array(old_labels)
    return false if added.empty?

    trigger_value.blank? || added.include?(trigger_value)
  end

  def status_changed_to_match?(trigger_value)
    return false unless @changed_attributes.key?('status')

    _, new_status = @changed_attributes['status']
    trigger_value.blank? || new_status.to_s == trigger_value.to_s
  end

  def execute_action(rule, pipeline_item)
    action       = rule[:action]
    action_value = rule[:action_value]
    return unless SUPPORTED_ACTIONS.include?(action)

    case action
    when 'move_to_stage'       then move_to_stage(pipeline_item, action_value)
    when 'move_to_pipeline'    then move_to_pipeline(pipeline_item, action_value)
    when 'assign_agent'        then assign_agent(action_value)
    when 'apply_label'         then apply_label(action_value)
    when 'send_ai_message'     then send_ai_message(@conversation, suggested_message: rule[:ai_message])
    when 'send_direct_message' then send_direct_message(@conversation, action_value)
    when 'send_template'       then send_template(@conversation, { id: action_value })
    when 'finalize'            then finalize(@conversation, action_value)
    end
  rescue StandardError => e
    Rails.logger.error "[StageAutomation] conv=#{@conversation.id} action=#{rule[:action]}: #{e.message}"
  end

  def move_to_stage(pipeline_item, target_stage_id)
    return if target_stage_id.blank?
    return if pipeline_item.pipeline_stage_id.to_s == target_stage_id.to_s

    pipeline     = pipeline_item.pipeline_stage.pipeline
    target_stage = pipeline.pipeline_stages.find_by(id: target_stage_id)
    return unless target_stage

    Pipelines::ConversationService.new(pipeline: pipeline, user: nil)
                                  .move_to_stage(pipeline_item, target_stage)
    Rails.logger.info "[StageAutomation] conv=#{@conversation.id} moved to stage=#{target_stage.name}"
  end

  # Move the pipeline_item to a different pipeline by updating its pipeline_id
  # and pipeline_stage_id in place. Preserves the row's primary key, entered_at,
  # custom_fields, stage_movements history and tasks. Skipped silently when the
  # conversation already has another item in the destination pipeline (the
  # (conversation_id, pipeline_id) unique index would otherwise reject the
  # update).
  def move_to_pipeline(pipeline_item, action_value)
    Rails.logger.info(
      "[StageAutomation] conv=#{@conversation.id} move_to_pipeline called " \
      "with action_value=#{action_value.inspect} (class=#{action_value.class})"
    )

    target_pipeline_id, target_stage_id = parse_move_to_pipeline_value(action_value)
    Rails.logger.info(
      "[StageAutomation] conv=#{@conversation.id} parsed target_pipeline_id=#{target_pipeline_id.inspect} " \
      "target_stage_id=#{target_stage_id.inspect}"
    )

    if target_pipeline_id.blank?
      Rails.logger.warn "[StageAutomation] move_to_pipeline aborted: target_pipeline_id blank"
      return
    end

    if pipeline_item.pipeline_id.to_s == target_pipeline_id.to_s
      Rails.logger.warn(
        "[StageAutomation] move_to_pipeline aborted: target equals current pipeline " \
        "(#{target_pipeline_id})"
      )
      return
    end

    target_pipeline = Pipeline.find_by(id: target_pipeline_id)
    unless target_pipeline
      Rails.logger.warn "[StageAutomation] move_to_pipeline aborted: target pipeline #{target_pipeline_id} not found"
      return
    end

    target_stage =
      if target_stage_id.present?
        target_pipeline.pipeline_stages.find_by(id: target_stage_id)
      else
        target_pipeline.pipeline_stages.ordered&.first || target_pipeline.pipeline_stages.first
      end

    unless target_stage
      Rails.logger.warn(
        "[StageAutomation] move_to_pipeline aborted: target stage not found " \
        "(target_pipeline=#{target_pipeline.id} stage_id=#{target_stage_id.inspect})"
      )
      return
    end

    if conversation_already_in_pipeline?(target_pipeline)
      Rails.logger.warn(
        "[StageAutomation] conv=#{@conversation.id} skipped move_to_pipeline: " \
        "another pipeline_item already exists in pipeline=#{target_pipeline.name}"
      )
      return
    end

    old_stage = pipeline_item.pipeline_stage

    begin
      pipeline_item.update!(
        pipeline_id: target_pipeline.id,
        pipeline_stage_id: target_stage.id
      )
    rescue StandardError => e
      Rails.logger.error(
        "[StageAutomation] move_to_pipeline pipeline_item.update! failed: " \
        "#{e.class}: #{e.message}"
      )
      raise
    end

    begin
      pipeline_item.stage_movements.create!(
        from_stage: old_stage,
        to_stage: target_stage,
        moved_by: Current.user,
        movement_type: 'cross_pipeline',
        notes: "Moved from pipeline '#{old_stage&.pipeline&.name}' to '#{target_pipeline.name}'"
      )
    rescue StandardError => e
      # Don't roll back the pipeline_item update if only the audit row fails —
      # log it so we still know, but the move itself stays.
      Rails.logger.error(
        "[StageAutomation] move_to_pipeline stage_movement create! failed: " \
        "#{e.class}: #{e.message}"
      )
    end

    Rails.logger.info(
      "[StageAutomation] conv=#{@conversation.id} moved to pipeline=#{target_pipeline.name} " \
      "stage=#{target_stage.name}"
    )
  end

  def parse_move_to_pipeline_value(value)
    return [nil, nil] if value.blank?

    case value
    when Hash
      pipeline_id = value['pipeline_id'] || value[:pipeline_id]
      stage_id    = value['stage_id'] || value[:stage_id]
      [pipeline_id, stage_id]
    when String, Symbol
      raw = value.to_s
      if raw.include?(':')
        pipeline_id, stage_id = raw.split(':', 2)
        [pipeline_id, stage_id]
      else
        [raw, nil]
      end
    else
      [nil, nil]
    end
  end

  def conversation_already_in_pipeline?(target_pipeline)
    @conversation
      .pipeline_items
      .where(pipeline_id: target_pipeline.id)
      .exists?
  end

  def assign_agent(agent_id)
    return if agent_id.blank?

    agent = User.find_by(id: agent_id)
    return unless agent

    @conversation.update!(assignee: agent)
    Rails.logger.info "[StageAutomation] conv=#{@conversation.id} assigned to agent=#{agent.name}"
  end

  def apply_label(label_value)
    return if label_value.blank?

    title = resolve_label_title(label_value)
    return if title.blank?

    current_labels = @conversation.label_list
    return if current_labels.include?(title)

    @conversation.update!(label_list: current_labels + [title])
    Rails.logger.info "[StageAutomation] conv=#{@conversation.id} label=#{title} applied"
  end

  # The frontend stores the Label UUID in action_value, but acts_as_taggable_on
  # compares against tags.name (the Label title). Translate UUIDs to titles
  # here so the rule lands the right tag instead of creating a garbage tag
  # named after the UUID.
  UUID_LABEL_REGEX = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/.freeze

  def resolve_label_title(value)
    raw = value.to_s
    return raw unless UUID_LABEL_REGEX.match?(raw)

    Label.where(id: raw).pick(:title) || raw
  end
end
