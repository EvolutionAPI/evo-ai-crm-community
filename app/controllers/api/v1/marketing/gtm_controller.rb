class Api::V1::Marketing::GtmController < Api::V1::BaseController
  RESOURCES = %w[tags triggers variables folders].freeze

  before_action :check_connected
  before_action :validate_resource!, only: %i[create_resource update_resource destroy_resource]

  # --- Leitura ---------------------------------------------------------

  def accounts
    respond_with(service.accounts)
  end

  def containers
    respond_with(service.containers(params[:account_id]))
  end

  def workspace
    respond_with(service.workspace(params[:account_id], params[:container_id]))
  end

  # --- Contêineres -------------------------------------------------------

  def create_container
    usage_context = params[:usage_context] == 'server' ? 'server' : 'web'
    respond_with(service.create_container(params[:account_id], params[:name], usage_context))
  end

  # --- Recursos (tags/acionadores/variáveis/pastas) ---------------------

  def create_resource
    respond_with(service.create_resource(params[:account_id], params[:container_id], params[:resource], resource_payload))
  end

  def update_resource
    respond_with(
      service.update_resource(params[:account_id], params[:container_id], params[:resource], params[:resource_id], resource_payload)
    )
  end

  def destroy_resource
    respond_with(service.delete_resource(params[:account_id], params[:container_id], params[:resource], params[:resource_id]))
  end

  # --- Importação ---------------------------------------------------------

  def import_container
    respond_with(service.import_container(params[:account_id], params[:container_id], params[:container_version]))
  end

  # --- Permissões / compartilhamento -----------------------------------

  def permissions
    respond_with(service.account_permissions(params[:account_id]))
  end

  def create_permission
    respond_with(
      service.create_account_permission(
        params[:account_id],
        params[:email],
        params[:account_permission] || 'user',
        params[:container_id],
        params[:container_permission] || 'edit'
      )
    )
  end

  def destroy_permission
    respond_with(service.delete_account_permission(params[:account_id], params[:permission_id]))
  end

  private

  def service
    @service ||= Google::TagManagerService.new
  end

  def check_connected
    return if Google::WorkspaceTokenService.new.connected?

    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Conta Google não conectada.', status: :unprocessable_entity)
  end

  def validate_resource!
    return if RESOURCES.include?(params[:resource])

    error_response(ApiErrorCodes::INVALID_PARAMETER, 'Tipo de recurso inválido.', status: :bad_request)
  end

  # O payload de um recurso GTM (tag/acionador/variável/pasta) é passado como
  # veio do frontend — a API do Google valida o schema por tipo, então só
  # repassamos o que a tela montou (name, type, parameter[], firingTriggerId
  # etc conforme o recurso).
  def resource_payload
    params.require(:resource_payload).permit!.to_h
  end

  def respond_with(result)
    if result.success
      success_response(data: result.data)
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error)
    end
  end
end
