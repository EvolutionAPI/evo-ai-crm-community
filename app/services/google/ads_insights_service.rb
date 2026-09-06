require 'net/http'

# Google::AdsInsightsService - substitui o workflow n8n "Google Ads Relatorio"
# chamando a Google Ads API (v19, GAQL) direto. Credenciais em
# Integrations::Hook(app_id: 'google_ads') — client_id/secret/refresh_token
# são do app OAuth próprio usado pra Ads (não a conexão google_workspace, que
# é outro app/escopo), developer_token é exigido pela API além do OAuth.
class Google::AdsInsightsService
  TOKEN_URL = 'https://www.googleapis.com/oauth2/v3/token'
  BASE_URL = 'https://googleads.googleapis.com/v19'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_ads')
  end

  def connected?
    @hook&.settings.present?
  end

  def campaigns(date_start:, date_stop:)
    search(<<~GAQL)
      SELECT customer.descriptive_name,
             campaign.id,
             campaign.name,
             campaign.status,
             campaign.advertising_channel_type,
             metrics.clicks,
             metrics.impressions,
             metrics.cost_micros,
             metrics.average_cpc,
             metrics.ctr,
             metrics.conversions,
             metrics.conversions_value
      FROM campaign
      WHERE segments.date BETWEEN '#{date_start}' AND '#{date_stop}'
    GAQL
  end

  def account_cost(date_start:, date_stop:)
    search(<<~GAQL)
      SELECT customer.descriptive_name, metrics.cost_micros
      FROM customer
      WHERE segments.date BETWEEN '#{date_start}' AND '#{date_stop}'
    GAQL
  end

  def top_search_terms(date_start:, date_stop:, order_by: 'metrics.impressions', limit: 20)
    search(<<~GAQL)
      SELECT search_term_view.search_term,
             campaign.id,
             campaign.name,
             campaign.status,
             metrics.impressions,
             metrics.clicks,
             metrics.cost_micros
      FROM search_term_view
      WHERE segments.date BETWEEN '#{date_start}' AND '#{date_stop}'
      ORDER BY #{order_by} DESC
      LIMIT #{limit}
    GAQL
  end

  private

  def search(query)
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    token = access_token
    return Result.new(success: false, error: 'Falha ao renovar o token do Google Ads.') unless token

    settings = @hook.settings
    customer_id = settings['customer_id'].to_s.gsub(/\D/, '')

    uri = URI("#{BASE_URL}/customers/#{customer_id}/googleAds:search")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['developer-token'] = settings['developer_token']
    login_customer_id = settings['login_customer_id'].to_s.gsub(/\D/, '')
    request['login-customer-id'] = login_customer_id if login_customer_id.present?
    request['Content-Type'] = 'application/json'
    request.body = { query: query }.to_json

    response = http.request(request)
    body = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::AdsInsightsService: search -> #{response.code} #{response.body}"
      return Result.new(success: false, error: body.is_a?(Array) ? body.dig(0, 'error', 'message') : body.dig('error', 'message'))
    end

    Result.new(success: true, data: body['results'] || [])
  rescue StandardError => e
    Rails.logger.error "Google::AdsInsightsService: search error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a Google Ads API.')
  end

  # Sem refresh automático salvo de volta (ao contrário de
  # Google::WorkspaceTokenService) porque esse token não expira o hook —
  # client_id/secret/refresh_token são estáveis; só o access_token de curta
  # duração é gerado a cada chamada. Simples e sem estado pra manter.
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
    Rails.logger.error "Google::AdsInsightsService: token refresh error: #{e.message}"
    nil
  end
end
