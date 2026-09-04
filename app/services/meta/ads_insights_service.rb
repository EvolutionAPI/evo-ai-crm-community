require 'net/http'

# Meta::AdsInsightsService - substitui o workflow n8n "Relatorio meta webhook"
# (Meta Geral/hora/idade_genero/regiao/posicionamento) chamando a Graph API
# Marketing (v23.0) direto, usando o user_access_token de longa duração já
# salvo em Channel::FacebookPage (mesma conexão usada pro canal de
# mensagens — precisa ter sido reautorizada com o escopo `ads_read`, ver
# FacebookChannelForm.tsx).
#
# Esse token é por instalação (uma Página conectada), não por conta de
# anúncios — o `ad_account_id` é passado em cada chamada porque uma mesma
# Business Manager pode ter várias contas de anúncio.
class Meta::AdsInsightsService
  BASE_URL = 'https://graph.facebook.com/v23.0'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  BREAKDOWNS = {
    'geral' => nil,
    'hora' => 'hourly_stats_aggregated_by_audience_time_zone',
    'idade_genero' => 'age,gender',
    'regiao' => 'region',
    'posicionamento' => 'impression_device,device_platform,platform_position,publisher_platform'
  }.freeze

  FIELDS = %w[
    campaign_name campaign_id adset_name adset_id ad_name ad_id
    spend impressions reach clicks ctr cpc cpm actions cost_per_action_type
  ].freeze

  def initialize
    @token = Channel::FacebookPage.first&.user_access_token
  end

  def connected?
    @token.present?
  end

  # conteudo: um dos BREAKDOWNS.keys ('geral', 'hora', 'idade_genero', 'regiao', 'posicionamento')
  def campaign_insights(ad_account_id:, conteudo:, date_start:, date_stop:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
    return Result.new(success: false, error: 'ID da conta de anúncios não informado.') if ad_account_id.blank?

    breakdown = BREAKDOWNS.fetch(conteudo) { BREAKDOWNS['geral'] }
    params = {
      access_token: @token,
      level: 'ad',
      fields: FIELDS.join(','),
      time_range: { since: date_start, until: date_stop }.to_json,
      time_increment: 1,
      limit: 500
    }
    params[:breakdowns] = breakdown if breakdown.present?

    get("/act_#{ad_account_id}/insights", params)
  end

  # Lista leve (sem insights) pra popular o seletor de conta no relatório —
  # troca o campo de digitar o act_id na mão por um dropdown. business_id:
  # quando presente, escopa às contas dessa Business Manager (donas +
  # clientes) em vez do /me/adaccounts pessoal — mesmas contas que só
  # aparecem dentro de uma BM (ver Meta::AdsManagerService#ad_accounts).
  def ad_accounts(business_id: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    fields = 'id,name,account_id'
    return get('/me/adaccounts', access_token: @token, fields: fields, limit: 500) if business_id.blank?

    owned = get("/#{business_id}/owned_ad_accounts", access_token: @token, fields: fields)
    return owned unless owned.success

    client = get("/#{business_id}/client_ad_accounts", access_token: @token, fields: fields)
    return client unless client.success

    Result.new(success: true, data: (owned.data + client.data).uniq { |a| a['id'] })
  end

  # Lista as Business Managers que o token tem acesso — nível acima da
  # conta, pra ver contas de clientes que não aparecem no /me/adaccounts.
  def business_managers
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    get('/me/businesses', access_token: @token, fields: 'id,name')
  end

  def campaigns(ad_account_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    get("/act_#{ad_account_id}/campaigns", access_token: @token, fields: 'id,name,status,objective', limit: 500)
  end

  # Usado pelo enriquecimento de WhatsappAdLead: o `source_id` capturado do
  # externalAdReplyInfo normalmente é o id do anúncio (ad_id) na Graph API.
  def ad(ad_id)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    get("/#{ad_id}", access_token: @token, fields: 'id,name,adset{id,name},campaign{id,name}')
  end

  private

  def get(path, params)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    response = http.request(Net::HTTP::Get.new(uri.request_uri))
    body = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::AdsInsightsService: GET #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: body.dig('error', 'message') || 'Falha ao consultar a Graph API da Meta.')
    end

    Result.new(success: true, data: body['data'] || body)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsInsightsService: GET #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a Graph API da Meta.')
  end
end
