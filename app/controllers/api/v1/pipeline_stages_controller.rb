class Api::V1::PipelineStagesController < Api::V1::BaseController
  DESCRIPTION_MAX_LENGTH = 500
  INACTIVITY_BASES = %w[no_customer_reply stage_stagnation].freeze

  require_permissions({
    index: 'pipeline_stages.read',
    show: 'pipeline_stages.read',
    create: 'pipeline_stages.create',
    update: 'pipeline_stages.update',
    destroy: 'pipeline_stages.delete',
    move_up: 'pipeline_stages.update',
    move_down: 'pipeline_stages.update',
    reorder: 'pipeline_stages.update',
    bulk_move_conversations: 'pipeline_stages.update'
  })
  before_action :fetch_pipeline
  
  before_action :fetch_pipeline_stage, only: [:show, :update, :destroy, :move_up, :move_down]
  before_action :reject_invalid_stage_type, only: [:create, :update]
  before_action :reject_invalid_automation_rules, only: [:create, :update]

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

  # stage_type is an enum: an unknown value raises ArgumentError on assignment, which the
  # global StandardError rescue turns into a 500. Callers that guess the value (the copilot
  # among them) deserve a 422 naming the accepted ones.
  def reject_invalid_stage_type
    stage = params[:pipeline_stage]
    return unless stage.respond_to?(:key?) && stage.key?(:stage_type)

    submitted = stage[:stage_type]
    return if PipelineStage.stage_types.key?(submitted.to_s)

    # A blank value is refused rather than skipped: the enum casts '' to nil, so letting it
    # through clears the stage_type of a stage that had one — and answers 200 doing it.
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: ["stage_type #{submitted.to_s.inspect} is not supported; " \
                "must be one of: #{PipelineStage.stage_types.keys.join(', ')}"],
      status: :unprocessable_entity
    )
  end

  # normalize_automation_rules drops what it cannot recognise, so a typo in a trigger used to
  # come back 200 with the rule silently gone. Reject the payload instead, naming what failed.
  def reject_invalid_automation_rules
    raw = params.dig(:pipeline_stage, :automation_rules)
    return if raw.blank?

    details = if raw.respond_to?(:to_unsafe_h)
                automation_rules_errors(raw.to_unsafe_h.with_indifferent_access)
              else
                ['automation_rules must be an object']
              end
    return if details.empty?

    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: details,
      status: :unprocessable_entity
    )
  end

  def automation_rules_errors(ar)
    details = []

    if ar.key?('description') && ar['description'].to_s.length > DESCRIPTION_MAX_LENGTH
      details << "automation_rules.description must be at most #{DESCRIPTION_MAX_LENGTH} characters"
    end

    # `rules` as anything but an array (an object keyed by index, say) is what a caller that
    # guesses the shape sends. Array() would turn it into pairs and rule_errors would raise
    # on them — a 500 out of the guard whose whole job is to answer 422.
    return details << 'automation_rules.rules must be an array' if ar.key?('rules') && !ar['rules'].is_a?(Array)

    Array(ar['rules']).each_with_index { |rule, index| details.concat(rule_errors(rule, index)) }

    details
  end

  def rule_errors(rule, index)
    return ["automation_rules.rules[#{index}] must be an object"] unless rule.respond_to?(:to_h)

    r       = rule.to_h.with_indifferent_access
    trigger = r[:trigger].to_s
    action  = r[:action].to_s
    errors  = []

    unless Pipelines::StageAutomationService::SUPPORTED_TRIGGERS.include?(trigger)
      errors << "automation_rules.rules[#{index}].trigger #{trigger.inspect} is not supported; " \
                "must be one of: #{Pipelines::StageAutomationService::SUPPORTED_TRIGGERS.join(', ')}"
    end

    unless Pipelines::StageAutomationService::SUPPORTED_ACTIONS.include?(action)
      errors << "automation_rules.rules[#{index}].action #{action.inspect} is not supported; " \
                "must be one of: #{Pipelines::StageAutomationService::SUPPORTED_ACTIONS.join(', ')}"
    end

    errors.concat(inactivity_trigger_value_errors(r[:trigger_value], index)) if trigger == 'inactivity'
    errors
  end

  # normalize_trigger_value coerces this object into shape rather than refusing it: an
  # unknown base becomes no_customer_reply, and a minutes the sweeper cannot read becomes 0,
  # which makes the rule fire on the next pass instead of after the delay that was asked for.
  def inactivity_trigger_value_errors(value, index)
    prefix = "automation_rules.rules[#{index}].trigger_value"
    return ["#{prefix} must be an object for the inactivity trigger"] unless value.is_a?(Hash)

    tv      = value.with_indifferent_access
    base    = tv[:base]
    minutes = tv[:minutes]
    errors  = []

    if base.present? && !INACTIVITY_BASES.include?(base.to_s)
      errors << "#{prefix}.base #{base.to_s.inspect} is not supported; " \
                "must be one of: #{INACTIVITY_BASES.join(', ')}"
    end

    if minutes.blank?
      errors << "#{prefix}.minutes is required for the inactivity trigger"
    elsif !minutes.to_s.match?(/\A[1-9]\d*\z/)
      errors << "#{prefix}.minutes #{minutes.to_s.inspect} is not a positive whole number of minutes"
    end

    errors
  end

  # There is no `description` column on pipeline_stages: the stage description lives at
  # automation_rules.description, and a top-level `description` is dropped by this permit.
  # The copilot catalog (evo-skyway-service, stageFields) mirrors this shape — keep both in
  # step when the accepted fields change.
  def pipeline_stage_params
    permitted = params.require(:pipeline_stage).permit(
      :name,
      :color,
      :stage_type,
      custom_fields: {}
    )

    raw_ar = params.dig(:pipeline_stage, :automation_rules)
    permitted[:automation_rules] = merge_automation_rules(raw_ar) if raw_ar.present?

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

  # automation_rules is a single jsonb column, so assigning it replaces the whole object.
  # An update that carries only `rules` would drop the stage description (and one that
  # carries only `description` would drop the rules), so the incoming keys are merged over
  # what is stored. Sending a key explicitly still overwrites it: `description: ''` clears
  # the description, `rules: []` clears the rules.
  def merge_automation_rules(raw)
    stored = @pipeline_stage&.automation_rules || {}

    stored.to_h.stringify_keys.merge(normalize_automation_rules(raw))
  end

  def normalize_automation_rules(raw)
    return {} unless raw.respond_to?(:to_unsafe_h)

    ar = raw.to_unsafe_h.with_indifferent_access
    result = {}

    # Not truncated: reject_invalid_automation_rules refuses anything over the limit before
    # this runs, and silently shortening what it let through would contradict that.
    result['description'] = ar['description'].to_s if ar.key?('description')

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
    base = 'no_customer_reply' unless INACTIVITY_BASES.include?(base)
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
