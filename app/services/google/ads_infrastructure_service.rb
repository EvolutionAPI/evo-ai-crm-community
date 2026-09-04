require 'net/http'

# Google::AdsInfrastructureService - substitui o "Gerenciador de
# Infraestrutura Google Ads" (fluxo de 8 passos: sub-conta, ação de
# conversão, conversões aprimoradas, vincular GA4, tracking template,
# lista de remarketing, sitelink, vínculo com o MCC) que originalmente só
# simulava as chamadas com IDs de Math.random(). Usa a mesma credencial de
# Integrations::Hook(app_id: 'google_ads') do Google::AdsInsightsService —
# client_id/secret/refresh_token (OAuth do app Ads, separado do Google
# Login), developer_token e login_customer_id (o MCC).
class Google::AdsInfrastructureService
  TOKEN_URL = 'https://www.googleapis.com/oauth2/v3/token'
  BASE_URL = 'https://googleads.googleapis.com/v19'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_ads')
  end

  def connected?
    @hook&.settings.present?
  end

  # Passo 1: cria uma sub-conta (Customer) sob o MCC.
  def create_customer_client(descriptive_name:, currency_code:, time_zone:)
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    mcc = login_customer_id
    return Result.new(success: false, error: 'login_customer_id (MCC) não configurado.') if mcc.blank?

    post("/customers/#{mcc}:createCustomerClient", {
      customerClient: { descriptiveName: descriptive_name, currencyCode: currency_code, timeZone: time_zone }
    })
  end

  # Passo 2: cria uma ação de conversão (categoria PURCHASE, tipo WEBPAGE).
  def create_conversion_action(customer_id:, name:)
    mutate(customer_id, 'conversionActions', [{
      create: { name: name, type: 'WEBPAGE', category: 'PURCHASE', status: 'ENABLED' }
    }])
  end

  # Passo 3: ativa Conversões Aprimoradas na ação de conversão já criada.
  def enable_enhanced_conversions(customer_id:, conversion_action_resource:)
    mutate(customer_id, 'conversionActions', [{
      update: { resourceName: conversion_action_resource, enhancedConversionsForLeadsEnabled: true },
      updateMask: 'enhancedConversionsForLeadsEnabled'
    }])
  end

  # Passo 4: vincula a propriedade GA4 à conta de anúncios.
  def link_ga4(customer_id:, ga4_property_id:)
    mutate(customer_id, 'productLinks', [{ create: { ga4PropertyId: ga4_property_id, status: 'ENABLED' } }])
  end

  # Passo 5: define o Tracking Template global da conta (ValueTrack).
  def set_tracking_template(customer_id:, tracking_template:)
    mutate_single(customer_id, 'customers', {
      update: { resourceName: "customers/#{customer_id}", trackingUrlTemplate: tracking_template },
      updateMask: 'trackingUrlTemplate'
    })
  end

  # Passo 6: cria uma lista de remarketing (visitantes dos últimos 30 dias).
  def create_remarketing_list(customer_id:, name:, membership_days: 30)
    mutate(customer_id, 'userLists', [{
      create: { name: name, membershipLifeSpan: membership_days, basicUserList: { ruleBasedUserListInfo: {} } }
    }])
  end

  # Passo 7: cria um asset de sitelink em nível de conta.
  def create_sitelink_asset(customer_id:, link_text:, final_url:)
    mutate(customer_id, 'assets', [{
      create: { type: 'SITELINK', sitelinkAsset: { linkText: link_text, finalUrls: [final_url] } }
    }])
  end

  # Passo 8: vincula a sub-conta ao MCC (relação de gerenciamento).
  def link_manager(customer_id:)
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    mcc = login_customer_id
    return Result.new(success: false, error: 'login_customer_id (MCC) não configurado.') if mcc.blank?

    mutate(customer_id, 'customerManagerLink', [{ create: { managerCustomer: "customers/#{mcc}", status: 'ACTIVE' } }])
  end

  private

  def login_customer_id
    @hook&.settings&.dig('login_customer_id').to_s.gsub(/\D/, '').presence
  end

  def mutate(customer_id, resource, operations)
    post("/customers/#{customer_id.to_s.gsub(/\D/, '')}/#{resource}:mutate", { operations: operations })
  end

  def mutate_single(customer_id, resource, operation)
    post("/customers/#{customer_id.to_s.gsub(/\D/, '')}/#{resource}:mutate", { operation: operation })
  end

  def post(path, body)
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    token = access_token
    return Result.new(success: false, error: 'Falha ao renovar o token do Google Ads.') unless token

    settings = @hook.settings
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['developer-token'] = settings['developer_token']
    request['login-customer-id'] = login_customer_id if login_customer_id.present?
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    response = http.request(request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::AdsInfrastructureService: #{path} -> #{response.code} #{response.body}"
      error_msg = parsed.is_a?(Array) ? parsed.dig(0, 'error', 'message') : parsed.dig('error', 'message')
      return Result.new(success: false, error: error_msg || 'Falha ao consultar a Google Ads API.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Google::AdsInfrastructureService: #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a Google Ads API.')
  end

  def access_token
    settings = @hook.settings
    uri = URI(TOKEN_URL)
    response = Net::HTTP.post_form(uri, {
                                      'grant_type' => 'refresh_token',
                                      'client_id' => settings['client_id'],
                                      'client_secret' => settings['client_secret'],
                                      'refresh_token' => settings['refresh_token']
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)['access_token']
  rescue StandardError => e
    Rails.logger.error "Google::AdsInfrastructureService: token refresh error: #{e.message}"
    nil
  end
end
