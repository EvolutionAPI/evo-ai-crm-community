require 'net/http'

# Google::Ga4InfrastructureService - substitui o "Gerenciador de Infraestrutura
# GA4" (fluxo de 8 passos: conta, propriedade, fluxo de dados web, medição
# avançada, dimensões personalizadas, eventos de conversão, link com Google
# Ads, secret do Measurement Protocol), que originalmente só simulava as
# chamadas com IDs fabricados via Math.random(). Cada passo aqui chama a
# GA4 Admin API de verdade, usando a mesma conexão OAuth "Google Login"
# (Google::WorkspaceTokenService) já usada por Google::AnalyticsInsightsService
# — precisa do escopo analytics.edit (ver Integrations::App), não só
# analytics.readonly.
#
# Criar uma CONTA nova (Passo 1) normalmente não é permitido pra apps OAuth
# comuns — a Admin API v1beta não expõe um `accounts.create` público pra
# a maioria dos desenvolvedores. Implementamos fiel ao endpoint documentado
# e deixamos o erro real da Google aparecer se não for permitido, em vez de
# fingir sucesso.
class Google::Ga4InfrastructureService
  ADMIN_API_BASE = 'https://analyticsadmin.googleapis.com/v1beta'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize(token_service: Google::WorkspaceTokenService.new)
    @token_service = token_service
  end

  def connected?
    @token_service.connected?
  end

  # Lista as contas GA4 que a conexão enxerga, pra popular o seletor —
  # necessário pros passos 2+ (criar propriedade dentro de uma conta
  # já existente), já que criar conta nova (Passo 1) raramente é permitido.
  def list_accounts
    get('/accounts', {})
  end

  # Passo 1: criar conta GA4. Ver aviso na doc da classe — provavelmente
  # retorna erro de permissão pra a maioria dos tokens.
  def create_account(display_name:)
    post('/accounts', { displayName: display_name, regionCode: 'BR' })
  end

  # Passo 2: criar propriedade dentro de uma conta existente.
  def create_property(account_name:, display_name:, time_zone:, currency_code:)
    post('/properties', {
      parent: account_name,
      displayName: display_name,
      timeZone: time_zone,
      currencyCode: currency_code
    })
  end

  # Passo 3: criar o fluxo de dados web (gera o Measurement ID G-XXXX).
  def create_web_data_stream(property_id:, display_name:, default_uri:)
    post("/properties/#{property_id}/webDataStreams", {
      displayName: display_name,
      defaultUri: default_uri
    })
  end

  # Passo 4: ativa Enhanced Measurement (pageviews, scroll, cliques de
  # saída, downloads, busca no site) no fluxo de dados web.
  def enable_enhanced_measurement(stream_id:)
    settings = {
      streamEnabled: true,
      scrollsEnabled: true,
      outboundClicksEnabled: true,
      siteSearchEnabled: true,
      videoEngagementEnabled: true,
      fileDownloadsEnabled: true
    }
    patch("/#{stream_id}/enhancedMeasurementSettings", settings, update_mask: settings.keys.join(','))
  end

  # Passo 5: cria dimensões personalizadas (escopo de evento).
  def create_custom_dimensions(property_id:, names:)
    results = names.map do |name|
      post("/properties/#{property_id}/customDimensions", {
        parameterName: name,
        displayName: name,
        scope: 'EVENT'
      })
    end
    failed = results.find { |r| !r.success }
    return failed if failed

    Result.new(success: true, data: { 'created' => results.map(&:data) })
  end

  # Passo 6: marca eventos como conversão (Key Events).
  def create_conversion_events(property_id:, event_names:)
    results = event_names.map do |name|
      post("/properties/#{property_id}/conversionEvents", { eventName: name })
    end
    failed = results.find { |r| !r.success }
    return failed if failed

    Result.new(success: true, data: { 'created' => results.map(&:data) })
  end

  # Passo 7: vincula a propriedade a uma conta do Google Ads.
  def link_google_ads(property_id:, customer_id:)
    post("/properties/#{property_id}/googleAdsLinks", { customerId: customer_id })
  end

  # Passo 8: gera um Measurement Protocol API Secret — este SIM tem
  # endpoint público real e funciona pra qualquer stream que você administre.
  def create_measurement_protocol_secret(stream_id:, display_name:)
    post("/#{stream_id}/measurementProtocolSecrets", { displayName: display_name })
  end

  private

  def token_or_error
    @token_service.access_token
  end

  def get(path, params)
    request_with_token(:get, path, params: params)
  end

  def post(path, body)
    request_with_token(:post, path, body: body)
  end

  def patch(path, body, params = {})
    request_with_token(:patch, path, body: body, params: params)
  end

  def request_with_token(method, path, params: {}, body: nil)
    token = token_or_error
    return Result.new(success: false, error: 'Sessão do Google expirada. Reconecte em Configurações > Integrações.') unless token

    uri = URI("#{ADMIN_API_BASE}#{path}")
    uri.query = URI.encode_www_form(params) if params.present?

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
    request = request_class.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    if body
      request['Content-Type'] = 'application/json'
      request.body = body.to_json
    end

    handle_response(http.request(request), path)
  rescue StandardError => e
    Rails.logger.error "Google::Ga4InfrastructureService: #{method.upcase} #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a GA4 Admin API.')
  end

  def handle_response(response, path)
    parsed = response.body.present? ? JSON.parse(response.body) : {}

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::Ga4InfrastructureService: #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao consultar a GA4 Admin API.')
    end

    Result.new(success: true, data: parsed)
  end
end
