class Pipelines::ConversationService
  def initialize(pipeline:, user: nil)
    @pipeline = pipeline
    @user = user
  end

  def add_conversation(conversation, stage: nil, custom_fields: {})
    stage ||= @pipeline.pipeline_stages.first
    return false unless stage

    prepare_conversation_for_pipeline(conversation)
    create_pipeline_item(conversation, stage, custom_fields)
  end

  def remove_conversation(conversation)
    pipeline_item = @pipeline.pipeline_items.find_by(conversation: conversation)
    return false unless pipeline_item

    pipeline_item.destroy!
    notify_conversation_removed(conversation)
    true
  rescue StandardError => e
    Rails.logger.error "Failed to remove conversation from pipeline: #{e.message}"
    false
  end

  def move_conversation_to_stage(conversation, new_stage, notes: nil)
    pipeline_item = @pipeline.pipeline_items.find_by(conversation: conversation)
    return false unless pipeline_item

    execute_stage_move(pipeline_item, new_stage, notes)
  end

  def move_to_stage(pipeline_item, new_stage)
    old_stage = pipeline_item.pipeline_stage
    success = pipeline_item.move_to_stage(new_stage, @user)

    if success
      notify_conversation_moved(pipeline_item, old_stage, new_stage)
      execute_stage_automation(pipeline_item, new_stage)
    end

    success
  rescue StandardError => e
    Rails.logger.error "Failed to move conversation to stage: #{e.message}"
    false
  end

  # Relocates an existing pipeline_item to a stage in a DIFFERENT pipeline,
  # in place (preserving the row + history), so the conversation leaves the
  # previous pipeline. Mirrors Pipelines::StageAutomationService#move_to_pipeline
  # for parity; same-pipeline moves use #move_to_stage.
  def move_to_pipeline_stage(pipeline_item, target_stage)
    return false if pipeline_item.pipeline_id == target_stage.pipeline_id

    old_stage = pipeline_item.pipeline_stage
    pipeline_item.update!(pipeline_id: target_stage.pipeline_id, pipeline_stage_id: target_stage.id)
    record_cross_pipeline_movement(pipeline_item, old_stage, target_stage)
    notify_conversation_moved(pipeline_item, old_stage, target_stage)
    execute_stage_automation(pipeline_item, target_stage)
    true
  rescue StandardError => e
    Rails.logger.error "Failed to move conversation across pipelines: #{e.message}"
    false
  end

  def bulk_move_conversations(conversation_ids, new_stage, notes: nil)
    results = { success: 0, failed: 0, errors: [] }

    conversation_ids.each do |conversation_id|
      conversation = Conversation.find_by(id: conversation_id)

      unless conversation
        results[:failed] += 1
        results[:errors] << "Conversation #{conversation_id} not found"
        next
      end

      if move_conversation_to_stage(conversation, new_stage, notes: notes)
        results[:success] += 1
      else
        results[:failed] += 1
        results[:errors] << "Failed to move conversation #{conversation_id}"
      end
    end

    results
  end

  def pipeline_statistics
    analytics_service.pipeline_statistics
  end

  def get_conversation_analytics(date_range: 30.days.ago..Time.current)
    analytics_service.get_conversation_analytics(date_range: date_range)
  end

  private

  def analytics_service
    @analytics_service ||= Pipelines::AnalyticsService.new(@pipeline)
  end

  def prepare_conversation_for_pipeline(conversation)
    conversation.reload

    # Only remove active items from OTHER pipelines (not this one)
    # This preserves completed journey history in the current pipeline
    other_pipeline_items = conversation.pipeline_items.where.not(pipeline_id: @pipeline.id)
    return unless other_pipeline_items.exists?

    Rails.logger.info "Pipeline Service: Removing conversation #{conversation.id} from #{other_pipeline_items.count} other pipeline(s)"
    other_pipeline_items.destroy_all
    conversation.reload
  end

  def create_pipeline_item(conversation, stage, custom_fields)
    pipeline_item = @pipeline.pipeline_items.create!(
      conversation: conversation,
      pipeline_stage: stage,
      assigned_by: @user,
      custom_fields: custom_fields
    )

    Rails.logger.info "Pipeline Service: Successfully created pipeline conversation for conversation #{conversation.id} " \
                      "in pipeline #{@pipeline.name}, stage #{stage.name}"

    notify_conversation_added(pipeline_item)
    pipeline_item
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to add conversation to pipeline: #{e.message}"
    false
  end

  def execute_stage_move(pipeline_item, new_stage, notes)
    old_stage = pipeline_item.pipeline_stage
    success = pipeline_item.move_to_stage(new_stage, @user)

    if success
      add_notes_to_movement(pipeline_item, notes) if notes.present?
      notify_conversation_moved(pipeline_item, old_stage, new_stage)
      execute_stage_automation(pipeline_item, new_stage)
    end

    success
  rescue StandardError => e
    Rails.logger.error "Failed to move conversation in pipeline: #{e.message}"
    false
  end

  def add_notes_to_movement(pipeline_item, notes)
    latest_movement = pipeline_item.stage_movements.last
    latest_movement.update!(notes: notes)
  end

  def record_cross_pipeline_movement(pipeline_item, old_stage, target_stage)
    pipeline_item.stage_movements.create!(
      from_stage: old_stage,
      to_stage: target_stage,
      moved_by: @user,
      movement_type: 'cross_pipeline',
      notes: "Moved from pipeline '#{old_stage&.pipeline&.name}' to '#{target_stage.pipeline.name}'"
    )
  rescue StandardError => e
    Rails.logger.error "Failed to record cross-pipeline movement: #{e.message}"
  end

  def execute_stage_automation(pipeline_item, stage)
    return if stage.automation_rules.blank?

    Rails.logger.info "Executing automation for conversation #{pipeline_item.id} in stage #{stage.name}"
  end

  def notify_conversation_added(pipeline_item)
    Rails.configuration.dispatcher.dispatch(
      'conversation.added_to_pipeline',
      Time.zone.now,
      pipeline_item: pipeline_item
    )
  end

  def notify_conversation_removed(conversation)
    Rails.configuration.dispatcher.dispatch(
      'conversation.removed_from_pipeline',
      Time.zone.now,
      conversation: conversation
    )
  end

  def notify_conversation_moved(pipeline_item, old_stage, new_stage)
    Rails.configuration.dispatcher.dispatch(
      'conversation.moved_in_pipeline',
      Time.zone.now,
      pipeline_item: pipeline_item,
      old_stage: old_stage,
      new_stage: new_stage
    )
  end
end
