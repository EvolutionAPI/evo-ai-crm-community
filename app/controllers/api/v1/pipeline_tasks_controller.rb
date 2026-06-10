class Api::V1::PipelineTasksController < Api::V1::BaseController
  before_action :set_pipeline_item, only: [:index, :create]
  before_action :set_task, only: [:show, :update, :destroy, :complete, :cancel, :reopen, :add_subtask, :move, :reorder]
  before_action :authorize_task, only: [:update, :destroy, :complete, :cancel, :reopen, :add_subtask, :move, :reorder]

  def index
    @tasks = tasks_scope.includes(:created_by, :assigned_to, :pipeline_item, :parent_task, :subtasks)
    
    # Filter by hierarchy level
    if params[:hierarchy].present?
      case params[:hierarchy]
      when 'all'
        # Include all tasks with hierarchy
      else
        # Default: only root tasks
        @tasks = @tasks.root_tasks
      end
    else
      @tasks = @tasks.root_tasks # Default to root tasks only
    end
    
    @tasks = apply_filters(@tasks)
    
    success_response(
      data: PipelineTaskSerializer.serialize_collection(@tasks, include_subtasks: true),
      message: 'Pipeline tasks retrieved successfully'
    )
  end

  def show
    success_response(
      data: PipelineTaskSerializer.serialize(
        @task,
        include_pipeline_item: true,
        include_parent: true,
        include_subtasks: true
      ),
      message: 'Pipeline task retrieved successfully'
    )
  end

  def create
    @task = @pipeline_item.tasks.new(task_params)
    @task.created_by = Current.user

    if @task.save
      success_response(
        data: PipelineTaskSerializer.serialize(@task, include_parent: true),
        message: 'Pipeline task created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Task validation failed',
        details: @task.errors
      )
    end
  end

  def update
    if @task.status_completed?
      error_response(
        ApiErrorCodes::BUSINESS_RULE_VIOLATION,
        'Cannot update completed tasks'
      )
      return
    end
    
    if @task.update(task_params)
      success_response(
        data: PipelineTaskSerializer.serialize(@task, include_parent: true, include_subtasks: true),
        message: 'Pipeline task updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Task validation failed',
        details: @task.errors
      )
    end
  end

  def destroy
    if @task.has_subtasks? && params[:delete_subtasks] != 'true'
      error_response(
        ApiErrorCodes::BUSINESS_RULE_VIOLATION,
        'Task has subtasks. Set delete_subtasks=true to delete all.',
        details: { subtask_count: @task.subtask_count }
      )
      return
    end
    
    @task.destroy!
    success_response(
      data: nil,
      message: 'Pipeline task deleted successfully'
    )
  rescue ActiveRecord::RecordNotDestroyed => e
    error_response(
      ApiErrorCodes::CANNOT_DELETE_RESOURCE,
      e.message
    )
  end

  def add_subtask
    subtask_params = task_params.merge(
      parent_task_id: @task.id,
      pipeline_item_id: @task.pipeline_item_id
    )
    
    @subtask = PipelineTask.new(subtask_params)
    @subtask.created_by = Current.user

    if @subtask.save
      success_response(
        data: PipelineTaskSerializer.serialize(@subtask, include_parent: true),
        message: 'Subtask created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Subtask validation failed',
        details: @subtask.errors,
        status: :unprocessable_entity
      )
    end
  end

  def move
    new_parent_id = params[:new_parent_id]
    new_position = params[:new_position]&.to_i

    if @task.move_to_parent(new_parent_id, new_position)
      success_response(
        data: PipelineTaskSerializer.serialize(@task, include_parent: true, include_subtasks: true),
        message: 'Task moved successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Failed to move task',
        details: @task.errors,
        status: :unprocessable_entity
      )
    end
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      e.message,
      status: :unprocessable_entity
    )
  end

  def reorder
    new_position = params[:position]&.to_i

    if new_position && @task.move_to_position(new_position)
      success_response(
        data: PipelineTaskSerializer.serialize(@task, include_parent: true, include_subtasks: true),
        message: 'Task reordered successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Failed to reorder task',
        details: @task.errors.any? ? @task.errors : ['Invalid position'],
        status: :unprocessable_entity
      )
    end
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      e.message,
      status: :unprocessable_entity
    )
  end

  def complete
    # Count descendants that will be completed
    descendants_to_complete = @task.descendants.reject(&:status_completed?)
    
    if @task.mark_as_completed(Current.user)
      task_data = PipelineTaskSerializer.serialize(
        @task,
        include_pipeline_item: true,
        include_subtasks: true
      )
      
      success_response(
        data: task_data.merge(descendants_completed_count: descendants_to_complete.count),
        message: 'Task completed successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Failed to complete task',
        details: @task.errors,
        status: :unprocessable_entity
      )
    end
  end

  def cancel
    if @task.mark_as_cancelled(Current.user)
      success_response(
        data: PipelineTaskSerializer.serialize(@task, include_pipeline_item: true),
        message: 'Task cancelled successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Failed to cancel task',
        details: @task.errors,
        status: :unprocessable_entity
      )
    end
  end

  def reopen
    # Count descendants that will be reopened
    descendants_to_reopen = @task.descendants.reject(&:status_pending?)
    
    if @task.reopen
      task_data = PipelineTaskSerializer.serialize(
        @task,
        include_pipeline_item: true,
        include_subtasks: true
      )
      
      success_response(
        data: task_data.merge(descendants_reopened_count: descendants_to_reopen.count),
        message: 'Task reopened successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Failed to reopen task',
        details: @task.errors,
        status: :unprocessable_entity
      )
    end
  end

  # rubocop:disable Metrics/AbcSize
  def statistics
    @stats = {
      total: tasks_scope.count,
      pending: tasks_scope.pending.count,
      completed: tasks_scope.completed.count,
      overdue: tasks_scope.overdue.count,
      due_today: tasks_scope.pending.due_today.count,
      due_this_week: tasks_scope.pending.due_this_week.count,
      by_type: tasks_scope.group(:task_type).count,
      by_assignee: tasks_scope.pending.group(:assigned_to_id).count,
      by_priority: tasks_scope.pending.group(:priority).count
    }

    success_response(
      data: @stats,
      message: 'Pipeline task statistics retrieved successfully'
    )
  end
  # rubocop:enable Metrics/AbcSize

  # Creates a PipelineTask on a conversation's active pipeline_item. Consumed by
  # the evo-flow Journey "Create Pipeline Task" node. A conversation with no
  # active pipeline_item degrades to a logged skip. created_by falls back through
  # the conversation/item owners because the Journey call is service-authenticated
  # (no Current.user) and the Community fork has no SuperAdmin system user.
  def for_conversation
    conversation = find_conversation(params[:conversation_id])
    return error_response(ApiErrorCodes::CONVERSATION_NOT_FOUND, 'Conversation not found') if conversation.nil?

    pipeline_item = conversation.pipeline_items.active.first
    return skip_task('no_pipeline_item', conversation) if pipeline_item.nil?

    creator = resolve_task_creator(conversation, pipeline_item)
    return skip_task('no_creator', conversation) if creator.nil?

    task = create_conversation_task(pipeline_item, creator)
    success_response(
      data: { created: true, task_id: task.id },
      message: 'Pipeline task created successfully',
      status: :created
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(ApiErrorCodes::VALIDATION_ERROR, e.message, details: e.record.errors.as_json)
  end

  private

  def find_conversation(ref)
    Conversation.find_by(id: ref) || Conversation.find_by(display_id: ref)
  end

  def create_conversation_task(pipeline_item, creator)
    pipeline_item.tasks.create!(
      title: params[:title],
      description: params[:description],
      task_type: params[:task_type].presence || 'call',
      priority: params[:priority].presence || 'low',
      assigned_to_id: resolve_assignee_id(params[:assigned_to_id]),
      due_date: calculate_due_date(params[:due_in]),
      created_by: creator
    )
  end

  # assigned_to has no DB foreign key and the belongs_to is optional, so a stale
  # assignee id (e.g. a deleted user) would be silently stored as a dangling
  # reference. Drop it and create the task unassigned rather than fail the whole
  # automation step.
  def resolve_assignee_id(assigned_to_id)
    return nil if assigned_to_id.blank?
    return assigned_to_id if User.exists?(id: assigned_to_id)

    Rails.logger.warn(
      "PipelineTasks#for_conversation: assigned_to_id #{assigned_to_id.inspect} " \
      'is not a known user; creating task unassigned'
    )
    nil
  rescue StandardError
    nil
  end

  def skip_task(reason, conversation)
    Rails.logger.warn(
      "PipelineTasks#for_conversation: conversation #{conversation.id} skipped (#{reason})"
    )
    success_response(
      data: { created: false, skipped: true, reason: reason },
      message: 'Pipeline task skipped'
    )
  end

  def resolve_task_creator(conversation, pipeline_item)
    Current.user || conversation.assignee || pipeline_item.assigned_by ||
      User.order(:created_at).first
  end

  DUE_DATE_UNITS = %w[minutes hours days weeks months].freeze

  def calculate_due_date(due_in)
    return nil if due_in.blank?
    return Time.zone.parse(due_in) if due_in.is_a?(String) && due_in.match?(/^\d{4}-\d{2}-\d{2}/)

    value, unit = due_in.to_s.split('.')
    return nil unless value.present? && DUE_DATE_UNITS.include?(unit)

    value.to_i.public_send(unit).from_now
  rescue StandardError => e
    Rails.logger.error "Error parsing due_date: #{e.message}"
    nil
  end

  def set_pipeline_item
    @pipeline = Pipeline.find(params[:pipeline_id])
    @pipeline_item = @pipeline.pipeline_items.find(params[:pipeline_item_id])
  end

  def set_task
    @pipeline = Pipeline.find(params[:pipeline_id]) if params[:pipeline_id].present?
    @task = PipelineTask.all.includes(subtasks: :subtasks, parent_task: :parent_task).find(params[:id])
  end

  def authorize_task
    authorize @task, policy_class: PipelineTaskPolicy
  end

  def tasks_scope
    if params[:pipeline_item_id].present?
      @pipeline_item.tasks
    else
      PipelineTask.all
    end
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def apply_filters(scope)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(task_type: params[:task_type]) if params[:task_type].present?
    scope = scope.where(priority: params[:priority]) if params[:priority].present?
    scope = scope.where(assigned_to_id: params[:assigned_to_id]) if params[:assigned_to_id].present?
    scope = scope.where(created_by_id: params[:created_by_id]) if params[:created_by_id].present?

    # Date filters
    scope = scope.where('due_date >= ?', params[:due_date_from]) if params[:due_date_from].present?
    scope = scope.where('due_date <= ?', params[:due_date_to]) if params[:due_date_to].present?
    scope = scope.due_today if params[:due_today] == 'true'
    scope = scope.due_this_week if params[:due_this_week] == 'true'
    scope = scope.past_due if params[:past_due] == 'true'

    scope
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def task_params
    params.require(:task).permit(
      :title,
      :description,
      :task_type,
      :due_date,
      :assigned_to_id,
      :priority,
      :status,
      :parent_task_id,
      :position,
      metadata: {}
    )
  end

end
