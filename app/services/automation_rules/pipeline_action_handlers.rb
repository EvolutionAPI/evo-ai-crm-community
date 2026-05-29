module AutomationRules
  # Shared pipeline action handlers consumed by both the modal-style
  # AutomationRules::ActionService and the flow-canvas-style
  # AutomationRules::FlowExecutionService. Single source of truth for the
  # three pipeline actions and the create_pipeline_task action so both
  # executor surfaces stay in lockstep — see app/services/automation_rules/README.md.
  #
  # Required instance state on the including class:
  #   @rule         — AutomationRule (logging + rubocop:disable signature parity)
  #   @conversation — Conversation (target of pipeline mutations)
  #
  # All methods are private when included, mirroring ActionService's original
  # surface. Public callers should drive `perform` (ActionService) or
  # `execute_node_action` (FlowExecutionService); they invoke these via send/
  # direct private dispatch.
  module PipelineActionHandlers
    private

    def assign_to_pipeline(pipeline_params)
      return unless pipeline_params[0]

      pipeline_id = extract_pipeline_id(pipeline_params[0])
      pipeline = Pipeline.find_by(id: pipeline_id)

      unless pipeline
        log_pipeline_not_found(pipeline_id)
        return
      end

      log_pipeline_assignment(pipeline)
      execute_pipeline_assignment(pipeline)
    end

    def update_pipeline_stage(stage_params)
      return unless stage_params[0]

      stage = find_stage_by_params(stage_params[0])
      return unless stage

      log_stage_update_attempt(stage)
      @conversation.reload

      pipeline_item = @conversation.pipeline_items.find_by(pipeline: stage.pipeline)

      if pipeline_item
        move_to_existing_stage(pipeline_item, stage)
      else
        auto_assign_and_move_to_stage(stage)
      end
    end

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def create_pipeline_task(task_params)
      return unless @conversation.pipeline_items.exists?

      pipeline_item = @conversation.pipeline_items.first
      params = task_params[0] || {}

      title = params[:title]
      description = params[:description]
      task_type = params[:task_type]
      priority = params[:priority]
      assigned_to_id = params[:assigned_to_id]
      due_in = params[:due_in]

      task = pipeline_item.tasks.create!(
        created_by_id: User.where(type: 'SuperAdmin').first&.id,
        assigned_to_id: assigned_to_id,
        title: title,
        description: description,
        task_type: task_type,
        due_date: calculate_due_date(due_in),
        priority: priority
      )

      Rails.logger.info "Automation Rule #{@rule.id}: Created task #{task.id} for conversation #{@conversation.id}"
    rescue StandardError => e
      Rails.logger.error "Automation Rule #{@rule.id}: Error creating pipeline task: #{e.message}"
      EvolutionExceptionTracker.new(e).capture_exception
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    def extract_pipeline_id(param)
      param.is_a?(Hash) ? param[:id] : param
    end

    def log_pipeline_assignment(pipeline)
      Rails.logger.info "Automation Rule #{@rule.id}: Assigning conversation #{@conversation.id} to pipeline #{pipeline.name} (ID: #{pipeline.id})"
    end

    def log_pipeline_not_found(pipeline_id)
      Rails.logger.warn "Automation Rule #{@rule.id}: Pipeline #{pipeline_id.inspect} not found; skipping assign_to_pipeline for conversation #{@conversation.id}"
    end

    def execute_pipeline_assignment(pipeline)
      @conversation.pipeline_items.destroy_all
      result = Pipelines::ConversationService.new(pipeline: pipeline, user: nil).add_conversation(@conversation)

      if result
        log_assignment_success(pipeline)
      else
        log_assignment_failure(pipeline)
      end
    end

    def log_assignment_success(pipeline)
      Rails.logger.info "Automation Rule #{@rule.id}: Successfully assigned conversation #{@conversation.id} to pipeline #{pipeline.name}"
    end

    def log_assignment_failure(pipeline)
      Rails.logger.error "Automation Rule #{@rule.id}: Failed to assign conversation #{@conversation.id} to pipeline #{pipeline.name}"
    end

    def find_stage_by_params(param)
      stage_id = param.is_a?(Hash) ? param[:id] : param
      PipelineStage.find_by(id: stage_id)
    end

    def log_stage_update_attempt(stage)
      Rails.logger.info "Automation Rule #{@rule.id}: Attempting to move conversation #{@conversation.id} to stage #{stage.name} (ID: #{stage.id})"
    end

    def move_to_existing_stage(pipeline_item, stage)
      service = Pipelines::ConversationService.new(pipeline: stage.pipeline, user: nil)
      success = service.move_to_stage(pipeline_item, stage)

      if success
        log_stage_move_success(stage)
      else
        log_stage_move_failure(stage)
      end
    end

    def auto_assign_and_move_to_stage(stage)
      log_auto_assignment_attempt(stage)

      service = Pipelines::ConversationService.new(pipeline: stage.pipeline, user: nil)
      result = service.add_conversation(@conversation, stage: stage.pipeline.pipeline_stages.first)

      if result
        log_auto_assignment_success(stage)
        move_to_target_stage_after_assignment(stage, service)
      else
        log_auto_assignment_failure(stage)
      end
    end

    def log_auto_assignment_attempt(stage)
      Rails.logger.info "Automation Rule #{@rule.id}: Conversation #{@conversation.id} not in pipeline #{stage.pipeline.name}, auto-assigning first"
    end

    def log_auto_assignment_success(stage)
      Rails.logger.info "Automation Rule #{@rule.id}: Successfully auto-assigned conversation to pipeline #{stage.pipeline.name}"
    end

    def log_auto_assignment_failure(stage)
      Rails.logger.error "Automation Rule #{@rule.id}: Failed to auto-assign conversation #{@conversation.id} to pipeline #{stage.pipeline.name}"
    end

    def move_to_target_stage_after_assignment(stage, service)
      @conversation.reload
      pipeline_item = @conversation.pipeline_items.find_by(pipeline: stage.pipeline)

      return unless pipeline_item && stage != stage.pipeline.pipeline_stages.first

      service.move_to_stage(pipeline_item, stage)
      log_stage_move_success(stage)
    end

    def log_stage_move_success(stage)
      Rails.logger.info "Automation Rule #{@rule.id}: Successfully moved conversation #{@conversation.id} to stage #{stage.name}"
    end

    def log_stage_move_failure(stage)
      Rails.logger.error "Automation Rule #{@rule.id}: Failed to move conversation #{@conversation.id} to stage #{stage.name}"
    end

    def calculate_due_date(due_in)
      return nil if due_in.blank?

      return Time.zone.parse(due_in) if due_in.is_a?(String) && due_in.match?(/^\d{4}-\d{2}-\d{2}/)

      value, unit = due_in.to_s.split('.')
      return nil unless value.present? && unit.present?

      value.to_i.send(unit).from_now
    rescue StandardError => e
      Rails.logger.error "Error parsing due_date: #{e.message}"
      nil
    end
  end
end
