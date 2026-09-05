require 'net/http'
require 'base64'
require 'securerandom'

# Meta::AdsManagerService - substitui o workflow n8n "painel meta relatorios
# campanhas gerenciador de anuncio" (o "Painel Tráfego"): navegar
# contas -> campanhas -> conjuntos -> anúncios -> criativo, editar
# campanha/conjunto/anúncio (nome/status/orçamento/criativo), duplicar
# anúncio e criar campanha nova (campanha+conjunto+anúncio+criativo, num
# fluxo só, igual o modal "Criar Campanha" do painel_trafego.html monta).
# Usa o mesmo user_access_token de Channel::FacebookPage que
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
    @page = Channel::FacebookPage.first
    @token = @page&.user_access_token
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

  # Cria campanha + conjunto de anúncios + criativo (upload de imagem/vídeo)
  # + anúncio, na mesma conta, num fluxo só — é o que o modal "Criar
  # Campanha" do painel_trafego.html monta e manda em `campanha` (payload
  # achatado, ver handleCreateCampaign no HTML). Qualquer etapa que falhar
  # para o fluxo e devolve o erro com o nome da etapa, sem tentar limpar as
  # etapas anteriores já criadas (a campanha/conjunto ficam PAUSED mesmo se
  # o resto falhar, então não há gasto — só sujeira pra apagar manualmente).
  def create_campaign_full(ad_account_id:, campanha:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
    return Result.new(success: false, error: 'Página do Facebook sem page_id configurado (necessário pro criativo).') if @page&.page_id.blank?

    act = "act_#{ad_account_id}"

    campaign = post("/#{act}/campaigns", {
                       name: campanha['name'],
                       status: campanha['status'].presence || 'PAUSED',
                       objective: campanha['objective'],
                       special_ad_categories: [].to_json,
                       # Exigido pela API quando o orçamento é definido no conjunto de
                       # anúncios (como aqui), não na campanha (CBO) — sem isso a Graph
                       # API recusa a criação com "Invalid parameter" (subcode 4834011).
                       is_adset_budget_sharing_enabled: false
                     })
    return step_error(campaign, 'campanha') unless campaign.success

    creative = build_creative(act: act, campanha: campanha)
    return step_error(creative, 'criativo') unless creative.success

    adset = post("/#{act}/adsets", {
                    name: campanha['adset_name'],
                    status: campanha['adset_status'].presence || 'PAUSED',
                    campaign_id: campaign.data['id'],
                    daily_budget: campanha['daily_budget'],
                    optimization_goal: campanha['optimization_goal'],
                    bid_strategy: campanha['bid_strategy'],
                    billing_event: 'IMPRESSIONS',
                    destination_type: (messaging_flow?(campanha) ? 'MESSENGER' : nil),
                    targeting: normalize_targeting(campanha['targeting'] || {}).to_json
                  }.compact)
    return step_error(adset, 'conjunto de anúncios') unless adset.success

    ad = post("/#{act}/ads", {
                 name: campanha['ad_name'],
                 status: campanha['ad_status'].presence || 'PAUSED',
                 adset_id: adset.data['id'],
                 creative: { creative_id: creative.data['id'] }.to_json
               })
    return step_error(ad, 'anúncio') unless ad.success

    Result.new(success: true, data: [{ 'body' => {
      'success' => true,
      'campaign_id' => campaign.data['id'],
      'adset_id' => adset.data['id'],
      'ad_id' => ad.data['id'],
      'creative_id' => creative.data['id']
    } }])
  end

  private

  # O modal "Criar Campanha" monta localização por pin (lat/lng + raio) como
  # `geo_locations.cities[].key = 'custom_location_pin'` — formato que nunca
  # existiu de verdade na Graph API (a chave certa pra pin é
  # `geo_locations.custom_locations[]`, sem key/name). Como esse fluxo nunca
  # tinha sido testado ponta a ponta, normaliza aqui em vez de mexer nos 6
  # formulários do painel_trafego.html.
  def normalize_targeting(targeting)
    geo = targeting['geo_locations']
    return targeting unless geo.is_a?(Hash) && geo['cities'].is_a?(Array)

    pins, real_cities = geo['cities'].partition { |c| c['key'] == 'custom_location_pin' }
    return targeting if pins.empty?

    custom_locations = pins.map do |pin|
      { 'latitude' => pin['latitude'], 'longitude' => pin['longitude'],
        'radius' => pin['radius'], 'distance_unit' => pin['distance_unit'] || 'kilometer' }
    end

    new_geo = geo.merge('custom_locations' => (geo['custom_locations'] || []) + custom_locations)
    if real_cities.empty?
      new_geo.delete('cities')
    else
      new_geo['cities'] = real_cities
    end

    targeting.merge('geo_locations' => new_geo)
  end

  def step_error(result, step_name)
    Result.new(success: false, data: [{ 'body' => { 'success' => false, 'step' => step_name } }],
               error: "Falha ao criar #{step_name}: #{result.error}")
  end

  # Faz upload da mídia (imagem via bytes base64 direto, vídeo via multipart
  # decodificado do base64) e monta o adcreative (object_story_spec) em
  # cima dela. `link_data`/`video_data` usam a própria página como destino
  # (link: facebook.com/<page_id>) porque o objetivo padrão do modal é
  # "mensagens" (OUTCOME_MESSAGING_CONVERSATIONS) — não há landing page
  # externa nesse fluxo, só o CTA de iniciar conversa.
  def build_creative(act:, campanha:)
    raw = campanha['asset_base64'].to_s
    base64 = raw.sub(/\Adata:[^;]+;base64,/, '')
    mimetype = campanha['asset_mimetype'].to_s
    page_id = @page.page_id
    messaging = messaging_flow?(campanha)
    # Precisa bater com o `destination_type` do adset (ver create_campaign_full)
    # — MESSAGE_PAGE sem isso, ou com um app_destination diferente do adset,
    # é a causa exata do "Incompatibilidade entre criativo e objetivo".
    cta = messaging ? { type: 'MESSAGE_PAGE', value: { app_destination: 'MESSENGER' } } : { type: 'LEARN_MORE' }

    story_spec = if mimetype.start_with?('video/')
                   # Vídeo não sobe como campo de formulário comum (ao contrário de
                   # imagem via `bytes`) — precisa de multipart de verdade.
                   video = post_multipart_video(act: act, binary: Base64.decode64(base64))
                   return video unless video.success

                   video_id = video.data['id']
                   thumbnail_url = poll_video_thumbnail(video_id: video_id)

                   {
                     page_id: page_id,
                     video_data: {
                       video_id: video_id,
                       image_url: thumbnail_url,
                       message: campanha['body'],
                       title: campanha['title'],
                       call_to_action: cta
                     }
                   }
                 else
                   image = post("/#{act}/adimages", { bytes: base64 })
                   return image unless image.success

                   image_hash = image.data['images']&.values&.first&.dig('hash')
                   return Result.new(success: false, error: 'Upload da imagem não retornou hash.') if image_hash.blank?

                   {
                     page_id: page_id,
                     link_data: {
                       image_hash: image_hash,
                       message: campanha['body'],
                       name: campanha['title'],
                       link: "https://www.facebook.com/#{page_id}",
                       call_to_action: cta
                     }
                   }
                 end

    post("/#{act}/adcreatives", { object_story_spec: story_spec.to_json })
  end

  def messaging_flow?(campanha)
    campanha['optimization_goal'].to_s.include?('CONVERSATIONS')
  end

  # POST multipart de verdade (a Graph API não aceita vídeo como campo de
  # formulário comum em base64, ao contrário de imagem via `bytes`).
  def post_multipart_video(act:, binary:)
    uri = URI("#{BASE_URL}/#{act}/advideos")
    boundary = SecureRandom.hex(16)

    post_body = []
    post_body << "--#{boundary}\r\n"
    post_body << "Content-Disposition: form-data; name=\"access_token\"\r\n\r\n#{@token}\r\n"
    post_body << "--#{boundary}\r\n"
    post_body << "Content-Disposition: form-data; name=\"source\"; filename=\"video.mp4\"\r\n"
    post_body << "Content-Type: video/mp4\r\n\r\n"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri.request_uri)
    request.body = post_body.join + binary.b + "\r\n--#{boundary}--\r\n"
    request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"

    response = http.request(request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::AdsManagerService: POST advideos -> #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao subir o vídeo pra Graph API.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: POST advideos error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao subir o vídeo.')
  end

  # O vídeo recém-enviado ainda está processando quando /advideos retorna —
  # o creative de video_data exige uma thumbnail já pronta, então espera
  # até 20s (Meta costuma gerar a primeira em poucos segundos) antes de
  # desistir e seguir sem thumbnail (a Graph API às vezes aceita mesmo
  # assim e completa depois).
  def poll_video_thumbnail(video_id:)
    8.times do
      result = get("/#{video_id}", fields: 'thumbnails')
      thumb = result.success ? result.data.dig('thumbnails', 'data')&.first&.dig('uri') : nil
      return thumb if thumb.present?

      sleep 2.5
    end
    nil
  end

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
