class Api::V1::MacrosController < Api::V1::BaseController
  # Use-vs-manage split (CRM-70): reading and executing are attendance and stay
  # on read/execute; creating and editing are Settings-screen management and
  # demand macros.manage (admin roles only) — except on a personal macro, which
  # its owner keeps editing and deleting (see check_update_permission! below).
  require_permissions({
    index: 'macros.read',
    show: 'macros.read',
    create: 'macros.manage',
    execute: 'macros.execute'
  })

  # `update` and `destroy` are not in require_permissions because their check
  # depends on the record, so it has to run after fetch_macro. They still answer to
  # the conventional check_<action>_permission! hook (see below), which is what the
  # mutating-actions gate guard and the permission-key conformance registry look for.
  EvoPermissionConcern.register_permission_key('macros.delete')

  before_action :fetch_macro, only: [:show, :update, :destroy, :execute]
  before_action :check_update_permission!, only: [:update]
  before_action :check_destroy_permission!, only: [:destroy]

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
    return macro_not_found if @macro.nil?

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
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
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
    return macro_not_found if @macro.nil?

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
        ApiErrorCodes::VALIDATION_ERROR,
        'Update failed',
        details: @macro.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    return macro_not_found if @macro.nil?

    @macro.destroy
    success_response(
      data: { id: @macro.id },
      message: 'Macro deleted successfully'
    )
  end

  def execute
    return macro_not_found if @macro.nil?

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

  # Same carve-out as destroy, for the same reason: a personal macro is not a shared
  # asset, so its owner keeps editing it without macros.manage (CRM-70 moved
  # create/update to that admin-only key). Without this the owner of a personal macro
  # could run it and delete it but never fix a typo in it.
  def check_update_permission!
    return if own_personal_macro?

    check_permission!('macros.manage', :user)
  end

  # Macro#set_visibility forces `personal` for every non-admin, so a macro an agent
  # creates belongs to that agent alone — deleting it is not deleting a shared asset.
  # Without this carve-out the least-privilege agent (CRM-190 revoked macros.delete)
  # could create personal macros it can never remove, and no admin could either: they
  # are absent from Macro.with_visibility for everyone but their owner. An unknown id
  # falls through to the key check, so a non-holder still gets 403 before any 404.
  def check_destroy_permission!
    return if own_personal_macro?

    check_permission!('macros.delete', :user)
  end

  def own_personal_macro?
    @macro&.personal? && @macro.created_by_id.present? && @macro.created_by_id == Current.user&.id
  end

  def macro_not_found
    error_response(
      ApiErrorCodes::MACRO_NOT_FOUND,
      "Macro with id #{params[:id]} not found",
      status: :not_found
    )
  end

end
