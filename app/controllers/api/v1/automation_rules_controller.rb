class Api::V1::AutomationRulesController < Api::V1::BaseController
  include Api::V1::ResourceLimitsHelper

  require_permissions({
    index: 'automation_rules.read',
    show: 'automation_rules.read',
    create: 'automation_rules.create',
    update: 'automation_rules.update',
    destroy: 'automation_rules.delete',
    clone: 'automation_rules.clone',
    runs: 'automation_rules.read'
  })

  before_action :fetch_automation_rule, only: [:show, :update, :destroy, :clone, :runs]
  before_action :validate_automation_limit, only: [:create]

  private

  def fetch_automation_rule
    @automation_rule = AutomationRule.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::AUTOMATION_RULE_NOT_FOUND,
      "Automation rule with id #{params[:id]} not found",
      status: :not_found
    )
  end

  public

  def index
    @automation_rules = AutomationRule.all

    apply_pagination
    
    paginated_response(
      data: AutomationRuleSerializer.serialize_collection(@automation_rules),
      collection: @automation_rules,
      message: 'Automation rules retrieved successfully'
    )
  end

  def show
    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule retrieved successfully'
    )
  end

  def create
    @automation_rule = AutomationRule.new(automation_rules_permit)
    @automation_rule.actions = params[:actions]
    @automation_rule.conditions = permitted_conditions
    @automation_rule.flow_data = params[:flow_data] if params[:flow_data]

    unless @automation_rule.valid?
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @automation_rule.errors.full_messages,
        status: :unprocessable_entity
      )
    end

    @automation_rule.save!
    process_attachments
    
    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule created successfully',
      status: :created
    )
  end

  def update
    ActiveRecord::Base.transaction do
      automation_rule_update
      process_attachments
      
      success_response(
        data: AutomationRuleSerializer.serialize(@automation_rule),
        message: 'Automation rule updated successfully'
      )
    rescue StandardError => e
      Rails.logger.error e
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Update failed',
        details: @automation_rule.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @automation_rule.destroy
    success_response(
      data: { id: @automation_rule.id },
      message: 'Automation rule deleted successfully'
    )
  end

  def clone
    new_rule = @automation_rule.dup
    new_rule.save!
    @automation_rule = new_rule

    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule cloned successfully',
      status: :created
    )
  end

  def runs
    runs_scope = @automation_rule.runs.recent.with_status(params[:status])
    @runs = runs_scope.limit(per_page).offset(page_offset)
    total = runs_scope.count

    success_response(
      data: @runs.map { |run| serialize_run(run) },
      meta: {
        pagination: {
          page: current_page,
          per_page: per_page,
          total_count: total,
          total_pages: (total / per_page.to_f).ceil
        }
      },
      message: 'Automation rule runs retrieved successfully'
    )
  end

  def process_attachments
    actions = @automation_rule.actions.filter_map { |k, _v| k if k['action_name'] == 'send_attachment' }
    return if actions.blank?

    actions.each do |action|
      blob_id = action['action_params']
      blob = ActiveStorage::Blob.find_by(id: blob_id)
      @automation_rule.files.attach(blob)
    end
  end

  private

  def automation_rule_update
    @automation_rule.update!(automation_rules_permit)
    @automation_rule.actions = params[:actions] if params[:actions]
    @automation_rule.conditions = permitted_conditions if params[:conditions]
    @automation_rule.flow_data = params[:flow_data] if params[:flow_data]
    @automation_rule.save!
  end

  def serialize_run(run)
    {
      id: run.id,
      automation_rule_id: run.automation_rule_id,
      event_name: run.event_name,
      status: run.status,
      started_at: run.started_at&.iso8601,
      finished_at: run.finished_at&.iso8601,
      duration_ms: run.duration_ms,
      error_message: run.error_message,
      payload: run.payload,
      steps: run.steps
    }
  end

  def current_page
    [params[:page].to_i, 1].max
  end

  def per_page
    [(params[:per_page] || 25).to_i, 100].min
  end

  def page_offset
    (current_page - 1) * per_page
  end

  # `values` is an array of scalars for regular operators but an object
  # `{to: [], from: []}` for `attribute_changed` (the shape
  # ConditionsFilterService reads), and `permit` cannot declare "array OR hash"
  # for one key — so each condition is permitted by hand.
  def permitted_conditions
    return [] unless params[:conditions].is_a?(Array)

    params[:conditions].filter_map do |condition|
      next unless condition.is_a?(ActionController::Parameters)

      permitted = condition.permit(:attribute_key, :filter_operator, :query_operator, :custom_attribute_type)
      permit_values(condition, permitted)
      permitted.to_h
    end
  end

  # An array whose items are not all scalars is rejected whole by `permit`,
  # which returns nil — leave `values` out entirely in that case, the way a
  # valueless condition (`is_present`) is stored.
  def permit_values(condition, permitted)
    values = condition[:values]

    if values.is_a?(ActionController::Parameters)
      permitted[:values] = values.permit(to: [], from: [])
    elsif values.is_a?(Array)
      scalars = condition.permit(values: [])[:values]
      permitted[:values] = scalars unless scalars.nil?
    end
  end

  def automation_rules_permit
    params.permit(
      :name, :description, :event_name, :active, :mode,
      actions: [:action_name, { action_params: [] }],
      flow_data: {
        nodes: [
          :id, :type,
          position: [:x, :y],
          data: {},
          measured: [:width, :height]
        ],
        edges: [
          :id, :source, :target, :sourceHandle, :targetHandle,
          data: {}
        ],
        variables: [
          :id, :name, :type, :default_value,
          data: {}
        ]
      }
    )
  end
end
