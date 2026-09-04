require 'net/http'

# Google::TagManagerService - integração com a API v2 do Google Tag Manager
# (https://tagmanager.googleapis.com/tagmanager/v2/) usando o token da conta
# Google conectada (Google::WorkspaceTokenService). Cobre leitura, criação,
# edição e remoção de contêineres/tags/acionadores/variáveis/pastas,
# importação de contêiner e gerenciamento de permissões (compartilhamento).
#
# NOTA: a API do GTM não expõe criação de "contas" — isso só existe pela UI
# do próprio tagmanager.google.com (limitação do Google, não deste serviço).
class Google::TagManagerService
  BASE_URL = 'https://tagmanager.googleapis.com/tagmanager/v2'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  # --- Leitura ---------------------------------------------------------

  def accounts
    get('/accounts', 'account')
  end

  def containers(account_id)
    get("/accounts/#{account_id}/containers", 'container')
  end

  def workspace(account_id, container_id)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Nenhum workspace encontrado neste contêiner.') unless workspace_id

    base = workspace_base(account_id, container_id, workspace_id)
    tags = get("#{base}/tags", 'tag')
    triggers = get("#{base}/triggers", 'trigger')
    variables = get("#{base}/variables", 'variable')
    folders = get("#{base}/folders", 'folder')
    templates = get("#{base}/templates", 'template')

    failed = [tags, triggers, variables, folders, templates].find { |r| !r.success }
    return failed if failed

    Result.new(success: true, data: {
                 workspace_id: workspace_id,
                 tags: tags.data,
                 triggers: triggers.data,
                 variables: variables.data,
                 folders: folders.data,
                 templates: templates.data
               })
  end

  # --- Contêineres -------------------------------------------------------

  def create_container(account_id, name, usage_context)
    post("/accounts/#{account_id}/containers", { name: name, usageContext: [usage_context] })
  end

  # --- Recursos do workspace (tags/acionadores/variáveis/pastas) ---------
  # `resource` é um dos: tags, triggers, variables, folders

  def create_resource(account_id, container_id, resource, payload)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    post("#{workspace_base(account_id, container_id, workspace_id)}/#{resource}", payload)
  end

  def update_resource(account_id, container_id, resource, resource_id, payload)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    put("#{workspace_base(account_id, container_id, workspace_id)}/#{resource}/#{resource_id}", payload)
  end

  def delete_resource(account_id, container_id, resource, resource_id)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    delete("#{workspace_base(account_id, container_id, workspace_id)}/#{resource}/#{resource_id}")
  end

  # --- Importação de contêiner ---------------------------------------
  # Sobe uma versão exportada (JSON do GTM) como uma nova versão do
  # contêiner de destino, substituindo o conteúdo do workspace padrão.

  def import_container(account_id, container_id, container_version_json)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    path = "/accounts/#{account_id}/containers/#{container_id}/workspaces/#{workspace_id}:import_container"
    post(path, { encodedContainerVersion: container_version_json }, query: 'fingerprint=&importMode=CREATE')
  end

  # --- Permissões / compartilhamento -----------------------------------

  def account_permissions(account_id)
    get("/accounts/#{account_id}/user_permissions", 'userPermission')
  end

  def create_account_permission(account_id, email, account_permission, container_id, container_permission)
    payload = {
      accountId: account_id,
      emailAddress: email,
      accountAccess: { permission: account_permission }
    }
    if container_id.present?
      payload[:containerAccess] = [{ containerId: container_id, permission: container_permission }]
    end
    post("/accounts/#{account_id}/user_permissions", payload)
  end

  def delete_account_permission(account_id, permission_id)
    delete("/accounts/#{account_id}/user_permissions/#{permission_id}")
  end

  private

  def default_workspace_id(account_id, container_id)
    result = get("/accounts/#{account_id}/containers/#{container_id}/workspaces", 'workspace')
    return nil unless result.success

    result.data.first&.dig('workspaceId')
  end

  def workspace_base(account_id, container_id, workspace_id)
    "/accounts/#{account_id}/containers/#{container_id}/workspaces/#{workspace_id}"
  end

  def token
    @token ||= Google::WorkspaceTokenService.new.access_token
  end

  def get(path, list_key)
    response = request(:get, path)
    return response unless response.success

    parsed = JSON.parse(response.data)
    Result.new(success: true, data: Array(parsed[list_key]))
  end

  def post(path, payload, query: nil)
    full_path = query.present? ? "#{path}?#{query}" : path
    response = request(:post, full_path, payload)
    return response unless response.success

    Result.new(success: true, data: JSON.parse(response.data))
  end

  def put(path, payload)
    response = request(:put, path, payload)
    return response unless response.success

    Result.new(success: true, data: JSON.parse(response.data))
  end

  def delete(path)
    request(:delete, path)
  end

  def request(method, path, payload = nil)
    return Result.new(success: false, error: 'Conta Google não conectada.') unless token

    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = build_request(method, uri, payload)
    request['Authorization'] = "Bearer #{token}"

    response = http.request(request)
    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::TagManagerService: #{method.upcase} #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: friendly_error(response.code))
    end

    Result.new(success: true, data: response.body)
  rescue StandardError => e
    Rails.logger.error "Google::TagManagerService: #{method.upcase} #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar o Google Tag Manager.')
  end

  def build_request(method, uri, payload)
    case method
    when :get
      Net::HTTP::Get.new(uri.request_uri)
    when :post
      req = Net::HTTP::Post.new(uri.request_uri)
      apply_json_body(req, payload)
    when :put
      req = Net::HTTP::Put.new(uri.request_uri)
      apply_json_body(req, payload)
    when :delete
      Net::HTTP::Delete.new(uri.request_uri)
    end
  end

  def apply_json_body(req, payload)
    if payload.present?
      req['Content-Type'] = 'application/json'
      req.body = payload.to_json
    end
    req
  end

  def friendly_error(code)
    case code.to_s
    when '401'
      'Sessão do Google expirada. Reconecte em Configurações > Integrações.'
    when '403'
      'Sem permissão para esta ação no Google Tag Manager com esta conta Google.'
    when '404'
      'Recurso não encontrado no Google Tag Manager.'
    when '409'
      'Conflito: o recurso foi alterado por outra pessoa. Recarregue e tente novamente.'
    else
      'Falha ao consultar o Google Tag Manager.'
    end
  end
end
