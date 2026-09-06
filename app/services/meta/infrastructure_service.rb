require 'net/http'

# Meta::InfrastructureService - substitui o "Gerenciador de Infraestrutura
# Meta API" (fluxo de 15 passos: criar conta de anúncios, dataset/CAPI,
# domínio, Instagram, WhatsApp, pasta de criativos, webhook de leads, etc.)
# que originalmente só SIMULAVA as chamadas (fetch() disparado mas resposta
# ignorada, IDs gerados com Math.random()). Aqui cada passo chama a Graph
# API de verdade, usando o mesmo user_access_token de Channel::FacebookPage
# já usado por Meta::AdsManagerService/AdsInsightsService — nada de token
# de sistema colado na tela.
#
# Vários desses endpoints exigem que o token seja de um admin da Business
# Manager alvo, e alguns (principalmente criar conta de anúncios via API)
# exigem "Extended Ad Account Management", uma permissão avançada que a
# Meta só concede a poucos parceiros — não fabricamos sucesso quando a API
# nega; devolvemos o erro real dela pro usuário.
class Meta::InfrastructureService
  BASE_URL = 'https://graph.facebook.com/v21.0'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @token = Channel::FacebookPage.first&.user_access_token
  end

  def connected?
    @token.present?
  end

  # Passo 1: criar conta de anúncios dentro da BM.
  # Exige "Extended Ad Account Management" (permissão avançada da Meta) —
  # a maioria das contas recebe erro de permissão aqui, o que é esperado.
  def create_ad_account(business_id:, name:, currency:, timezone_id:)
    post("/#{business_id}/adaccount", {
      name: name,
      currency: currency,
      timezone_id: timezone_id,
      end_advertiser: business_id,
      media_agency: business_id
    })
  end

  # Passo 2: cria o Dataset (Pixel unificado) na BM.
  def create_dataset(business_id:, name:)
    post("/#{business_id}/datasets", { name: name })
  end

  # Passo 3: ativa Correspondência Avançada Automática e First-Party
  # Cookies no dataset. NÃO existe um endpoint público simples que "gere"
  # um token de acesso da Conversions API a partir daqui — isso é feito
  # pelo Events Manager (Configurações > API de Conversões > Gerar token
  # de acesso). Não fabricamos um token falso; devolvemos só o resultado
  # real desta configuração.
  def configure_dataset(dataset_id:)
    post("/#{dataset_id}", {
      enable_automatic_matching: true,
      first_party_cookie_status: 'FIRST_PARTY_COOKIES_ENABLED'
    })
  end

  # Passo 4: vincula o dataset como ativo de mensuração da conta de anúncios.
  def link_dataset_to_account(dataset_id:, ad_account_id:, business_id:)
    post("/#{dataset_id}/shared_accounts", { account_id: ad_account_id, business: business_id })
  end

  # Passo 5: registra/verifica domínio na BM (owned_domains).
  def associate_domain(business_id:, domain:)
    post("/#{business_id}/owned_domains", { domain: domain })
  end

  # Passo 6: conecta a conta do Instagram à Página do Facebook.
  def connect_instagram_to_page(page_id:, instagram_account_id:)
    post("/#{page_id}", { instagram_account_id: instagram_account_id })
  end

  # Passo 7: dá à conta de anúncios permissão pra anunciar usando a Página.
  def link_page_to_ad_account(business_id:, page_id:, ad_account_id:)
    post("/#{business_id}/assigned_users", {
      asset: page_id,
      user: ad_account_id,
      tasks: %w[ADVERTISE ANALYZE].to_json
    })
  end

  # Passo 8: vincula a conta do WhatsApp Business (WABA) à conta de
  # anúncios (Click-to-WhatsApp Ads) e associa o número à Página.
  def link_whatsapp_to_ad_account(ad_account_id:, waba_id:, page_id:, phone_number_id:)
    r1 = post("/#{ad_account_id}/whatsapp_business_accounts", { whatsapp_business_account_id: waba_id })
    return r1 unless r1.success

    post("/#{page_id}", { page_whatsapp_number: phone_number_id })
  end

  # Passo 9: cria pasta na Biblioteca de Criativos da conta de anúncios.
  def create_creative_folder(ad_account_id:, name:)
    post("/#{ad_account_id}/adimagefolders", { name: name })
  end

  # Passo 10: padrão de nomenclatura/UTMs — preferência só do nosso lado,
  # não existe recurso correspondente na Graph API. Guardamos no
  # Integrations::Hook do Meta (mesmo hook que guarda outras config leves)
  # em vez de inventar uma chamada à API que não existe.
  def save_naming_conventions(campaign:, adset:, ad:, utm:)
    hook = Integrations::Hook.account_hooks.find_or_initialize_by(app_id: 'meta_infra_naming')
    hook.settings = (hook.settings || {}).merge(
      'campaign' => campaign, 'adset' => adset, 'ad' => ad, 'utm' => utm
    )
    hook.save!
    Result.new(success: true, data: { 'saved' => true })
  rescue StandardError => e
    Result.new(success: false, error: e.message)
  end

  # Passo 11: inscreve a Página pra receber leads instantâneos em tempo real.
  def subscribe_leads_webhook(page_id:)
    post("/#{page_id}/subscribed_apps", { subscribed_fields: ['leadgen'].to_json })
  end

  # Passo 12: registra o número na Cloud API do WhatsApp (envio de mensagens).
  # Exige o PIN de verificação em duas etapas configurado pra esse número.
  def register_whatsapp_number(phone_number_id:, pin:)
    return Result.new(success: false, error: 'PIN de verificação em duas etapas do número é obrigatório.') if pin.blank?

    post("/#{phone_number_id}/register", { messaging_product: 'whatsapp', pin: pin })
  end

  # Passo 13: lê o diagnóstico de Qualidade de Correspondência de Eventos (EMQ).
  def check_event_quality(dataset_id:)
    get("/#{dataset_id}/stats", {})
  end

  # Passo 14: compartilha a conta de anúncios com uma BM parceira externa.
  def grant_partner_access(ad_account_id:, business_id:, partner_business_id:)
    post("/#{ad_account_id}/agencies", {
      business: business_id,
      partner_business_id: partner_business_id,
      permitted_tasks: %w[MANAGE ANALYZE ADVERTISE].to_json
    })
  end

  # Passo 15: aceita os Termos de Anúncios de Cadastro (Lead Ads) pra Página.
  def accept_lead_ads_tos(page_id:, business_id:)
    post("/#{page_id}/leadgen_tos", { business_id: business_id })
  end

  private

  def get(path, params)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params.merge(access_token: @token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    handle_response(http.request(Net::HTTP::Get.new(uri.request_uri)), path)
  rescue StandardError => e
    Rails.logger.error "Meta::InfrastructureService: GET #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a Graph API da Meta.')
  end

  def post(path, body)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(body.merge(access_token: @token))

    handle_response(http.request(request), path)
  rescue StandardError => e
    Rails.logger.error "Meta::InfrastructureService: POST #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao gravar na Graph API da Meta.')
  end

  def handle_response(response, path)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::InfrastructureService: #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao consultar a Graph API da Meta.')
    end

    Result.new(success: true, data: parsed)
  end
end
