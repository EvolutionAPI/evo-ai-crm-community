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

  def hub_client
    @hub_client ||= EvolutionHub::Client.new
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
