# Proxy autenticado pra endpoints "self" do Evolution Hub. Permite o
# frontend do EvoCRM mostrar dropdown de Meta Apps disponíveis antes de
# criar canal sem precisar bater no Hub direto (que exigiria expor a
# API key global ao browser).
#
# Endpoints:
#   GET /api/v1/integrations/evolution_hub/meta_app_options
#       → repassa GET /api/v1/me/meta-app-options do Hub
#       Resposta:
#         { allowed_modes: ["shared","byo"], byo_credentials: [...],
#           shared_allowed_by_plan: bool, byo_allowed_by_plan: bool }
#
#   GET /api/v1/integrations/evolution_hub/plan
#       → repassa GET /api/v1/me/plan do Hub
#       Resposta: { slug, name, allow_shared_meta_app, allow_own_meta_app, ... }
#
# Auth: usuário autenticado no CRM (qualquer role). Não autoriza recurso
# específico — quem pode chamar API do CRM pode ver as opções do tenant.
class Api::V1::Integrations::EvolutionHubController < Api::V1::BaseController
  # Everything the embed widget needs, minus `connection_url` (see below).
  PUBLIC_CONNECT_INFO_FIELDS = %w[
    channel_id channel_type channel_name status can_connect platform_name
    meta_app_id meta_config_id meta_scopes byo_config_missing
  ].freeze

  before_action :ensure_hub_enabled

  def meta_app_options
    response = hub_client.meta_app_options
    # Hub devolve { "data": {...} } — desempacotamos pro frontend ficar
    # com shape estável { allowed_modes: [...] } direto.
    payload = response.is_a?(Hash) ? (response['data'] || {}) : {}
    render json: payload, status: :ok
  rescue EvolutionHub::Client::ConfigurationError, EvolutionHub::Client::RequestError => e
    handle_hub_error(e)
  end

  def plan
    payload = hub_client.my_plan
    render json: payload, status: :ok
  rescue EvolutionHub::Client::ConfigurationError, EvolutionHub::Client::RequestError => e
    handle_hub_error(e)
  end

  # The caller sends inbox_id, never the channel token: trusting a caller-supplied
  # token would let any token connect any channel.
  def connect_info
    payload = hub_client.public_connect_info(hub_channel_token!(:show?))
    render json: public_connect_info_payload(payload), status: :ok
  rescue EvolutionHub::Client::ConfigurationError, EvolutionHub::Client::RequestError => e
    handle_hub_error(e)
  end

  def whatsapp_connect
    missing = EvolutionHub::Client::SIGNUP_REQUIRED_FIELDS.select { |k| params[k].blank? }
    if missing.any?
      return render json: { error: "Parâmetros obrigatórios ausentes: #{missing.join(', ')}",
                            code: 'MISSING_REQUIRED_FIELD' }, status: :bad_request
    end

    hub_client.public_whatsapp_connect(
      hub_channel_token!(:update?),
      params.permit(*EvolutionHub::Client::SIGNUP_FIELDS).to_h.symbolize_keys
    )
    render json: { success: true }, status: :ok
  rescue EvolutionHub::Client::ConfigurationError, EvolutionHub::Client::RequestError => e
    handle_hub_error(e)
  end

  # Preview de canais já existentes no Hub. Usado pela tela de Settings
  # do EvoCRM pra confirmar que a integração está OK e mostrar o que
  # já está lá.
  def channels
    payload = hub_client.list_channels
    render json: payload, status: :ok
  rescue EvolutionHub::Client::ConfigurationError, EvolutionHub::Client::RequestError => e
    handle_hub_error(e)
  end

  # Canais Hub elegíveis pra serem LINKADOS num novo inbox do CRM.
  # Filtra: (a) os que já estão atrelados a algum inbox local (linkar 2x
  # gera mensagens duplicadas) e (b) opcionalmente por tipo (?type=whatsapp).
  #
  # Usado pelo dropdown "Usar canal existente" no modal de criação de inbox.
  def available_channels
    # Defesa em profundidade (anti-vazamento cross-tenant): quando
    # HUB_ALLOW_EXISTING_CHANNELS=false (deploy enterprise/SaaS), a listagem de
    # canais existentes do Hub é DESLIGADA no backend, não só escondida no front.
    # A listagem usa credenciais GLOBAIS sem filtro de tenant → vazaria conexões
    # de outras agências. Default ON (community standalone inalterado).
    unless hub_allow_existing_channels?
      return render json: { error: 'Feature disabled', code: 'HUB_EXISTING_CHANNELS_DISABLED' },
                    status: :forbidden
    end

    payload = hub_client.list_channels
    raw = payload.is_a?(Hash) ? (payload['channels'] || payload['data'] || []) : payload
    raw = [] unless raw.is_a?(Array)

    type_filter = params[:type].to_s
    raw = raw.select { |c| c['type'] == type_filter } if type_filter.present?

    linked_ids = already_linked_hub_channel_ids
    available = raw.reject { |c| linked_ids.include?(c['id']) }

    render json: { channels: available, count: available.size }, status: :ok
  rescue EvolutionHub::Client::ConfigurationError, EvolutionHub::Client::RequestError => e
    handle_hub_error(e)
  end

  private

  # Mesma flag do GlobalConfigController#hub_allow_existing_channels? — default
  # true (community standalone inalterado); false no enterprise/SaaS desliga a
  # listagem de canais existentes (anti-vazamento cross-tenant).
  def hub_allow_existing_channels?
    value = GlobalConfigService.load('HUB_ALLOW_EXISTING_CHANNELS', 'true')
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def hub_client
    @hub_client ||= EvolutionHub::Client.new
  end

  # The permission is passed in, not derived from action_name: a future action
  # reaching this helper would silently inherit whatever the fallback was.
  def hub_channel_token!(permission)
    inbox = Inbox.find(params[:inbox_id])
    authorize inbox, permission

    token = ::EvolutionHub::ChannelReconciler.hub_channel_token_of(inbox.channel)
    raise ActiveRecord::RecordNotFound, 'Inbox sem canal do Evolution Hub' if token.blank?

    token
  end

  # `connection_url` embeds the channel token, and this response goes to the
  # browser — the same token client.rb redacts out of error messages.
  def public_connect_info_payload(payload)
    return {} unless payload.is_a?(Hash)

    payload.slice(*PUBLIC_CONNECT_INFO_FIELDS)
  end

  def ensure_hub_enabled
    return if MetaBaseUrl.enabled?

    render json: { error: 'Evolution Hub não está habilitado neste workspace.' },
           status: :service_unavailable
  end

  def handle_hub_error(err)
    Rails.logger.error("EvolutionHub proxy failed: #{err.class} — #{err.message}")
    render json: { error: err.message, code: err.try(:code) }.compact,
           status: :bad_gateway
  end

  # Coleta os hub channel_ids já em uso por algum Channel local.
  # Whatsapp guarda em provider_config['evolution_hub']['channel_id'];
  # FacebookPage/Instagram em evolution_hub_meta['channel_id'].
  def already_linked_hub_channel_ids
    ids = []
    ids.concat(
      Channel::Whatsapp
        .where("provider_config -> 'evolution_hub' ->> 'channel_id' IS NOT NULL")
        .pluck(Arel.sql("provider_config -> 'evolution_hub' ->> 'channel_id'"))
    )
    ids.concat(
      Channel::FacebookPage
        .where("evolution_hub_meta ->> 'channel_id' IS NOT NULL")
        .pluck(Arel.sql("evolution_hub_meta ->> 'channel_id'"))
    )
    ids.concat(
      Channel::Instagram
        .where("evolution_hub_meta ->> 'channel_id' IS NOT NULL")
        .pluck(Arel.sql("evolution_hub_meta ->> 'channel_id'"))
    )
    ids.compact.to_set
  end
end
