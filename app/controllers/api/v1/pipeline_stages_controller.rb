class Api::V1::PipelineStagesController < Api::V1::BaseController
  require_permissions({
    index: 'pipeline_stages.read',
    show: 'pipeline_stages.read',
    create: 'pipeline_stages.create',
    update: 'pipeline_stages.update',
    destroy: 'pipeline_stages.delete'
  })
  before_action :fetch_pipeline
  
  before_action :fetch_pipeline_stage, only: [:show, :update, :destroy, :move_up, :move_down]

  def index
    @pipeline_stages = @pipeline.pipeline_stages.ordered.includes(pipeline_items: [:conversation])
    
    success_response(
      data: PipelineStageSerializer.serialize_collection(@pipeline_stages),
      message: 'Pipeline stages retrieved successfully'
    )
  end

  def show
    success_response(
      data: PipelineStageSerializer.serialize(@pipeline_stage),
      message: 'Pipeline stage retrieved successfully'
    )
  end

  def create
    @pipeline_stage = @pipeline.pipeline_stages.new(pipeline_stage_params)
    set_next_position

    if @pipeline_stage.save
      success_response(
        data: PipelineStageSerializer.serialize(@pipeline_stage),
        message: 'Pipeline stage created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @pipeline_stage.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def update
    if @pipeline_stage.update(pipeline_stage_params)
      success_response(
        data: PipelineStageSerializer.serialize(@pipeline_stage),
        message: 'Pipeline stage updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @pipeline_stage.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    if @pipeline_stage.pipeline_items.exists?
      return error_response(
        ApiErrorCodes::BUSINESS_RULE_VIOLATION,
        'Cannot delete stage with conversations. Move conversations to another stage first.',
        status: :unprocessable_entity
      )
    end

    @pipeline_stage.destroy
    reorder_stages_after_deletion
    success_response(
      data: { id: @pipeline_stage.id },
      message: 'Pipeline stage deleted successfully'
    )
  end

  def move_up
    swap_positions(@pipeline_stage, @pipeline_stage.previous_stage) if @pipeline_stage.previous_stage
    render_stage_with_pipeline
  end

  def move_down
    swap_positions(@pipeline_stage, @pipeline_stage.next_stage) if @pipeline_stage.next_stage
    render_stage_with_pipeline
  end

  def reorder
    stage_orders = params[:stage_orders] || []

    ActiveRecord::Base.transaction do
      # First, set all stages to negative positions to avoid uniqueness conflicts
      # Using update_all for performance and to avoid uniqueness constraint violations
      @pipeline.pipeline_stages.update_all('position = -position') # rubocop:disable Rails/SkipsModelValidations

      # Then set the new positions
      stage_orders.each_with_index do |stage_id, index|
        # Using update_all for bulk position updates without triggering callbacks
        @pipeline.pipeline_stages.where(id: stage_id).update_all(position: index + 1) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    @pipeline_stages = @pipeline.pipeline_stages.ordered.includes(:pipeline_items)
    success_response(
      data: PipelineStageSerializer.serialize_collection(@pipeline_stages),
      message: 'Pipeline stages reordered successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      'Failed to reorder pipeline stages',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def bulk_move_conversations
    from_stage = @pipeline.pipeline_stages.find(params[:from_stage_id])
    to_stage = @pipeline.pipeline_stages.find(params[:to_stage_id])

    ActiveRecord::Base.transaction do
      from_stage.pipeline_items.find_each do |pipeline_item|
        pipeline_item.move_to_stage(to_stage, Current.user)
      end
    end

    moved_count = from_stage.pipeline_items.count
    success_response(
      data: { moved_count: moved_count },
      message: "#{moved_count} conversations moved successfully"
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      'Failed to move conversations',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  private

  def fetch_pipeline
    @pipeline = Pipeline.find(params[:pipeline_id])
    authorize @pipeline, :view?
  end

  def fetch_pipeline_stage
    @pipeline_stage = @pipeline.pipeline_stages.find(params[:id])
  end

  def pipeline_stage_params
    permitted = params.require(:pipeline_stage).permit(
      :name,
      :color,
      :stage_type,
      custom_fields: {}
    )

    raw_ar = params.dig(:pipeline_stage, :automation_rules)
    permitted[:automation_rules] = normalize_automation_rules(raw_ar) if raw_ar.present?

    allowed_display_types = %w[text number currency percent link date list checkbox].freeze

    # Normalize custom_fields and keep only supported local attribute metadata
    if permitted[:custom_fields].present?
      attributes = permitted[:custom_fields]['attributes'] || []
      attributes = Array(attributes).map(&:to_s).reject(&:blank?)

      raw_definitions = permitted[:custom_fields]['attribute_definitions']
      attribute_definitions = if raw_definitions.is_a?(Hash)
                                raw_definitions.each_with_object({}) do |(key, value), acc|
                                  next if key.blank?
                                  next unless value.is_a?(Hash) || value.is_a?(ActionController::Parameters)

                                  definition = value.to_h.stringify_keys
                                  display_type = definition['attribute_display_type'].to_s
                                  next unless allowed_display_types.include?(display_type)

                                  normalized = {
                                    'attribute_display_name' => definition['attribute_display_name'].presence || key.to_s,
                                    'attribute_display_type' => display_type
                                  }

                                  if display_type == 'list'
                                    list_values = Array(definition['attribute_values']).map(&:to_s).reject(&:blank?)
                                    normalized['attribute_values'] = list_values if list_values.present?
                                  end

                                  acc[key.to_s] = normalized
                                end
                              else
                                {}
                              end

      attribute_definitions.slice!(*attributes)
      permitted[:custom_fields] = { 'attributes' => attributes }
      permitted[:custom_fields]['attribute_definitions'] = attribute_definitions if attribute_definitions.present?
    end

    permitted
  end

  def normalize_automation_rules(raw)
    return {} unless raw.respond_to?(:to_h)

    ar = raw.to_unsafe_h.with_indifferent_access
    result = {}

    result['description'] = ar['description'].to_s.slice(0, 500) if ar.key?('description')

    if ar['rules'].is_a?(Array)
      valid_triggers = Pipelines::StageAutomationService::SUPPORTED_TRIGGERS
      valid_actions  = Pipelines::StageAutomationService::SUPPORTED_ACTIONS

      result['rules'] = ar['rules'].filter_map do |rule|
        next unless rule.respond_to?(:to_h)

        r       = rule.to_h.with_indifferent_access
        trigger = r[:trigger].to_s
        action  = r[:action].to_s
        next unless valid_triggers.include?(trigger) && valid_actions.include?(action)

        normalized = {
          'trigger'       => trigger,
          'trigger_value' => normalize_trigger_value(trigger, r[:trigger_value]),
          'action'        => action,
          'action_value'  => r[:action_value].to_s.slice(0, 255)
        }
        # Stable id for inactivity idempotency + optional AI prompt text.
        normalized['id'] = r[:id].to_s.slice(0, 64) if r[:id].present?
        normalized['ai_message'] = r[:ai_message].to_s.slice(0, 512) if r[:ai_message].present?
        normalized
      end
    end

    result
  end

  # For the `inactivity` trigger the value is an object { minutes, base };
  # every other trigger keeps a plain string.
  def normalize_trigger_value(trigger, value)
    return value.to_s.slice(0, 255) unless trigger == 'inactivity'

    v = value.respond_to?(:to_h) ? value.to_h.with_indifferent_access : {}
    base = v[:base].to_s
    base = 'no_customer_reply' unless %w[no_customer_reply stage_stagnation].include?(base)
    { 'minutes' => v[:minutes].to_i, 'base' => base }
  end

  def set_next_position
    last_stage = @pipeline.pipeline_stages.order(:position).last
    @pipeline_stage.position = last_stage ? last_stage.position + 1 : 1
  end

  def reorder_stages_after_deletion
    deleted_position = @pipeline_stage.position
    # Using update_all for bulk position updates after deletion
    @pipeline.pipeline_stages.where('position > ?', deleted_position)
             .update_all('position = position - 1') # rubocop:disable Rails/SkipsModelValidations
  end

  def swap_positions(stage1, stage2)
    return unless stage1 && stage2

    ActiveRecord::Base.transaction do
      # Get the positions before swapping
      pos1 = stage1.position
      pos2 = stage2.position

      # Use negative positions to avoid uniqueness conflicts
      temp_position = -pos1
      stage1.update!(position: temp_position)
      stage2.update!(position: pos1)
      stage1.update!(position: pos2)
    end
  end

  def render_stage_with_pipeline
    @pipeline_stages = @pipeline.pipeline_stages.ordered.includes(:pipeline_items)
    render :index
  end

end
