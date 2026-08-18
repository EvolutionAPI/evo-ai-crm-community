class Api::V1::MacrosController < Api::V1::BaseController
  require_permissions({
    index: 'macros.read',
    show: 'macros.read',
    create: 'macros.create',
    update: 'macros.update',
    execute: 'macros.execute'
  })

  # `destroy` is not in require_permissions because its check depends on the record,
  # so it has to run after fetch_macro. It still answers to the conventional
  # check_<action>_permission! hook (see below), which is what the mutating-actions
  # gate guard and the permission-key conformance registry look for.
  EvoPermissionConcern.register_permission_key('macros.delete')

  before_action :fetch_macro, only: [:show, :update, :destroy, :execute]
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
    # CRM-195: scope the direct-by-id lookup by the SAME visibility rule as the list
    # (Macro.with_visibility = global + the caller's own personal), instead of a raw
    # find_by. Otherwise a third party reaches another user's PERSONAL macro by UUID
    # (show/update/destroy/execute) even though the list hides it — an out-of-scope
    # read/write. Rendering 404 here halts the before_action chain, so a caller that
    # DOES hold the action's base permission but targets an out-of-scope id (another
    # user's personal macro, or an unknown id) gets a uniform 404 — never a 200 leak.
    # Note the two distinct gates by action: show/update/execute carry a
    # require_permissions entry that 403s a caller missing macros.read/update/execute
    # BEFORE this runs; destroy has no such entry, so its key check runs AFTER, in
    # check_destroy_permission! — which is exactly why the 404 lands before that gate.
    @macro = Macro.with_visibility(current_user, params).find_by(id: params[:id])
    macro_not_found if @macro.nil?
  end

  # Macro#set_visibility forces `personal` for every non-admin, so a macro an agent
  # creates belongs to that agent alone — deleting it is not deleting a shared asset.
  # Without this carve-out the least-privilege agent (CRM-190 revoked macros.delete)
  # could create personal macros it can never remove, and no admin could either: they
  # are absent from Macro.with_visibility for everyone but their owner.
  #
  # CRM-195 changed the order this gate sees: fetch_macro now scopes by
  # Macro.with_visibility and renders 404 in the before_action BEFORE this hook runs,
  # so by the time we get here @macro is always in the caller's scope (their own
  # personal or a global). An id outside the scope — an unknown id OR another user's
  # personal macro — already 404'd and never reaches the key check. So this only ever
  # decides between "own personal → skip the key" and "global → require macros.delete".
  # This is a deliberate divergence from labels/canned_responses/message_templates,
  # whose destroy still gates before the fetch (403 for a non-holder on any id): here
  # hiding "user X has a personal macro at this UUID" outranks a uniform 403.
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
