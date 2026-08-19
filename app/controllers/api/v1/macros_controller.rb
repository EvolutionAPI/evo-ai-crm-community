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
    # CRM-195: scope the direct-by-id lookup by the same rule as the list, so another
    # user's PERSONAL macro answers 404 instead of leaking through 200/403. The 404
    # halts the before_action chain — see check_destroy_permission! for what that
    # ordering costs and why it is worth it.
    @macro = Macro.with_visibility(current_user, params).find_by(id: params[:id])
    macro_not_found if @macro.nil?
  end

  # CRM-190 carve-out: Macro#set_visibility forces `personal` for every non-admin, so a
  # macro an agent creates is its own, not a shared asset — without this it could create
  # personal macros nobody, not even an admin, is able to remove.
  #
  # CRM-195 moved fetch_macro's scoped 404 AHEAD of this gate, so @macro is always in the
  # caller's scope by now: this only decides "own personal -> skip the key" vs "global ->
  # require macros.delete". Deliberate divergence from labels/canned_responses/
  # message_templates, which still gate before the fetch: hiding "user X has a personal
  # macro at this UUID" outranks a uniform 403. What that leaves open on GLOBAL ids is
  # pinned by macros_visibility_scope_rbac_spec.
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
