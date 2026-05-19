class Api::V1::MacrosController < Api::V1::BaseController
  require_permissions({
    index: 'macros.read',
    show: 'macros.read',
    create: 'macros.create',
    update: 'macros.update',
    destroy: 'macros.delete',
    execute: 'macros.execute'
  })

  before_action :fetch_macro, only: [:show, :update, :destroy, :execute]

  def index
    @macros = Macro.with_visibility(current_user, params)
    
    apply_pagination
    
    paginated_response(
      data: MacroSerializer.serialize_collection(@macros),
      collection: @macros,
      message: 'Macros retrieved successfully'
    )
  end

  def show
    if @macro.nil?
      return error_response(
        code: ApiErrorCodes::MACRO_NOT_FOUND,
        message: "Macro with id #{params[:id]} not found",
        status: :not_found
      )
    end
    
    success_response(
      data: MacroSerializer.serialize(@macro),
      message: 'Macro retrieved successfully'
    )
  end

  def create
    macro_params = macros_with_user.except(:visibility).merge(created_by_id: current_user.id)
    @macro = Macro.new(macro_params)
    @macro.set_visibility(current_user, permitted_params)
    @macro.actions = params[:actions]

    unless @macro.valid?
      return error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Validation failed',
        details: @macro.errors.full_messages,
        status: :unprocessable_entity
      )
    end

    @macro.save!
    process_attachments
    
    success_response(
      data: MacroSerializer.serialize(@macro),
      message: 'Macro created successfully',
      status: :created
    )
  end

  def update
    ActiveRecord::Base.transaction do
      update_params = macros_with_user.except(:visibility)
      @macro.update!(update_params)
      @macro.set_visibility(current_user, permitted_params)
      process_attachments
      @macro.save!
      
      success_response(
        data: MacroSerializer.serialize(@macro),
        message: 'Macro updated successfully'
      )
    rescue StandardError => e
      Rails.logger.error e
      error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Update failed',
        details: @macro.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @macro.destroy
    success_response(
      data: { id: @macro.id },
      message: 'Macro deleted successfully'
    )
  end

  def execute
    executions = ::MacrosExecutionJob.perform_now(@macro, conversation_ids: params[:conversation_ids], user: Current.user)

    execution_results = Array(executions).compact.map do |exec|
      {
        id: exec.id,
        conversation_id: exec.conversation_id,
        status: exec.status,
        error_message: exec.error_message,
        actions_result: exec.actions_result
      }
    end

    success_response(
      data: { macro_id: @macro.id, conversation_ids: params[:conversation_ids], executions: execution_results },
      message: 'Macro execution completed'
    )
  end

  private

  def process_attachments
    actions = @macro.actions.filter_map { |k, _v| k if k['action_name'] == 'send_attachment' }
    return if actions.blank?

    actions.each do |action|
      blob_id = action['action_params']
      blob = ActiveStorage::Blob.find_by(id: blob_id)
      @macro.files.attach(blob)
    end
  end

  def permitted_params
    params.permit(
      :name, :visibility,
      actions: [:action_name, { action_params: [] }]
    )
  end

  def macros_with_user
    permitted_params.merge(updated_by_id: current_user.id)
  end

  def fetch_macro
    @macro = Macro.find_by(id: params[:id])
  end

end
