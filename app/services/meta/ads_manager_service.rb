require 'net/http'

# Meta::AdsManagerService - substitui o workflow n8n "painel meta relatorios
# campanhas gerenciador de anuncio" (o "Painel Tráfego"): navegar
# contas -> campanhas -> conjuntos -> anúncios -> criativo, editar
# campanha/conjunto/anúncio (nome/status/orçamento/criativo) e duplicar
# anúncio. Usa o mesmo user_access_token de Channel::FacebookPage que
# Meta::AdsInsightsService (precisa do escopo ads_read/ads_management).
#
# Os métodos devolvem exatamente a forma que
# dashboards-src/painel_trafego.html já espera do n8n (arrays com uma
# posição, campos "dados campanhas"/"insights", body.success) — o HTML só
# trocou a URL que chama, a lógica de renderização é a mesma.
class Meta::AdsManagerService
  BASE_URL = 'https://graph.facebook.com/v23.0'

  # Campos que a UI de edição realmente expõe — nunca repassa o `edicao` cru
  # pra API sem passar por este filtro, mesmo a origem sendo confiável
  # (defesa em profundidade: um bug no front não vira uma escrita arbitrária
  # na Graph API).
  EDITABLE_FIELDS = {
    'campaign' => %w[name status objective daily_budget lifetime_budget],
    'adset' => %w[name status daily_budget lifetime_budget targeting],
    'ad' => %w[name status ad_creative]
  }.freeze

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @token = Channel::FacebookPage.first&.user_access_token
  end

  def connected?
    @token.present?
  end

  # business_id: quando presente, escopa às contas dessa Business Manager
  # (donas + clientes) em vez do /me/adaccounts global — usado pelo nível
  # "BM" do Painel Tráfego (BM > Contas > Campanhas > ...).
  def ad_accounts(business_id: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    fields = 'id,name,account_id,balance,spend_cap,is_prepay_account,amount_spent,currency'
    if business_id.present?
      owned = get("/#{business_id}/owned_ad_accounts", fields: fields)
      return owned unless owned.success

      client = get("/#{business_id}/client_ad_accounts", fields: fields)
      return client unless client.success

      raw_accounts = (owned.data + client.data).uniq { |a| a['id'] }
    else
      result = get('/me/adaccounts', fields: fields)
      return result unless result.success

      raw_accounts = result.data
    end

    accounts = raw_accounts.map do |account|
      insights = get("/#{account['id']}/insights",
                      fields: 'impressions,reach,spend,clicks,cpc,ctr,actions', level: 'account')
      account.merge(
        'id' => account['account_id'] || account['id'].to_s.delete_prefix('act_'),
        'insights' => insights.success ? insights.data : []
      )
    end

    Result.new(success: true, data: [{ 'lista_final_contas_de_anuncios' => accounts }])
  end

  # Lista as Business Managers que o token tem acesso — nível acima de
  # "Contas" no Painel Tráfego.
  def business_managers
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    result = get('/me/businesses', fields: 'id,name')
    return result unless result.success

    Result.new(success: true, data: [{ 'lista_bms' => result.data }])
  end

  def campaigns_tree(ad_account_id:, date_start:, date_stop:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    structural = get(
      "/act_#{ad_account_id}/campaigns",
      fields: 'id,name,status,objective,' \
              'adsets{name,status,daily_budget,targeting,promoted_object,start_time,end_time,' \
              'optimization_goal,bid_strategy,ads{name,status,adcreative{name,body,image_url,video_id}}}',
      limit: 200
    )
    return structural unless structural.success

    insights = get(
      "/act_#{ad_account_id}/insights",
      fields: 'campaign_id,campaign_name,adset_id,adset_name,ad_id,ad_name,impressions,reach,spend,clicks,cpc,ctr,actions',
      level: 'ad',
      time_range: { since: date_start, until: date_stop }.to_json,
      limit: 500
    )
    return insights unless insights.success

    Result.new(success: true, data: [{ 'dados campanhas' => { 'data' => structural.data }, 'insights' => { 'data' => insights.data } }])
  end

  def creative_details(ad_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    ad = get("/#{ad_id}", fields: 'name,creative{name,body,title,image_url,thumbnail_url,video_id}')
    return ad unless ad.success

    creative = ad.data['creative'] || {}
    video = {}
    if creative['video_id'].present?
      video_result = get("/#{creative['video_id']}", fields: 'permalink_url,source')
      video = video_result.success ? video_result.data : {}
    end

    Result.new(success: true, data: [{
      'imagem' => creative['image_url'],
      'video' => video['source'],
      'thumbnail_url' => creative['thumbnail_url'] || video['permalink_url']
    }])
  end

  # nivel: 'campaign' | 'adset' | 'ad'. edicao: hash já filtrado por
  # EDITABLE_FIELDS pelo controller antes de chegar aqui.
  def update(id:, edicao:)
    result = post("/#{id}", edicao)
    Result.new(success: result.success, data: [{ 'body' => { 'success' => result.success } }], error: result.error)
  end

  def duplicate_ad(id:, edicao: {})
    result = post("/#{id}/copies", edicao)
    return Result.new(success: false, data: [{ 'body' => { 'success' => false } }], error: result.error) unless result.success

    Result.new(success: true, data: [{ 'body' => { 'success' => true, 'copied_campaign_id' => result.data['copied_ad_id'] || result.data['ad_id'] } }])
  end

  private

  def get(path, params)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params.merge(access_token: @token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    response = http.request(Net::HTTP::Get.new(uri.request_uri))
    body = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::AdsManagerService: GET #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: body.dig('error', 'message') || 'Falha ao consultar a Graph API da Meta.')
    end

    Result.new(success: true, data: body['data'] || body)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: GET #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a Graph API da Meta.')
  end

  def post(path, body)
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(body.merge(access_token: @token))

    response = http.request(request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::AdsManagerService: POST #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao gravar na Graph API da Meta.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: POST #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao gravar na Graph API da Meta.')
  end
end
