require 'net/http'

# Google::AnalyticsInsightsService - GA4 Data API (analyticsdata.googleapis.com),
# usando o mesmo token OAuth da conexão "Google Login" (google_workspace —
# ver Google::WorkspaceTokenService), agora com o escopo analytics.readonly.
# Ao contrário do Google Ads, a Data API do GA4 não exige developer token,
# então não precisa de uma credencial própria em Integrations::Hook — só o
# `property_id` (Analytics > Admin > Configurações da propriedade > ID da
# propriedade), passado por request como o ad_account_id do Meta.
class Google::AnalyticsInsightsService
  DATA_API_BASE = 'https://analyticsdata.googleapis.com/v1beta'
  ADMIN_API_BASE = 'https://analyticsadmin.googleapis.com/v1beta'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize(token_service: Google::WorkspaceTokenService.new)
    @token_service = token_service
  end

  def connected?
    @token_service.connected?
  end

  # Lista as propriedades GA4 que a conta conectada enxerga, pra preencher um
  # <select> em vez do usuário digitar o property_id na mão (Admin API —
  # accountSummaries já vem com as properties aninhadas, uma chamada só).
  def list_properties
    result = get(ADMIN_API_BASE, '/accountSummaries', pageSize: 200)
    return result unless result.success

    properties = (result.data['accountSummaries'] || []).flat_map do |account|
      (account['propertySummaries'] || []).map do |property|
        {
          'property_id' => property['property'].to_s.delete_prefix('properties/'),
          'display_name' => property['displayName'],
          'account_id' => account['account'].to_s.delete_prefix('accounts/'),
          'account_name' => account['displayName']
        }
      end
    end

    Result.new(success: true, data: properties)
  end

  # metrics/dimensions: arrays de nomes da API (ex: ['sessions','activeUsers'],
  # ['date'] ou ['sessionDefaultChannelGroup']) — ver
  # https://developers.google.com/analytics/devguides/reporting/data/v1/api-schema
  def run_report(property_id:, date_start:, date_stop:, dimensions:, metrics:)
    return Result.new(success: false, error: 'Google Analytics não conectado (Configurações > Integrações > Google Login).') unless connected?
    return Result.new(success: false, error: 'ID da propriedade GA4 não informado.') if property_id.blank?

    body = {
      dateRanges: [{ startDate: date_start, endDate: date_stop }],
      dimensions: dimensions.map { |name| { name: name } },
      metrics: metrics.map { |name| { name: name } }
    }

    post(DATA_API_BASE, "/properties/#{property_id}:runReport", body)
  end

  def traffic_overview(property_id:, date_start:, date_stop:)
    run_report(
      property_id: property_id, date_start: date_start, date_stop: date_stop,
      dimensions: ['date'],
      metrics: %w[sessions activeUsers newUsers screenPageViews conversions]
    )
  end

  def traffic_by_channel(property_id:, date_start:, date_stop:)
    run_report(
      property_id: property_id, date_start: date_start, date_stop: date_stop,
      dimensions: ['sessionDefaultChannelGroup'],
      metrics: %w[sessions activeUsers conversions]
    )
  end

  private

  def token_or_error
    token = @token_service.access_token
    return token if token

    nil
  end

  def get(base, path, params)
    token = token_or_error
    return Result.new(success: false, error: 'Sessão do Google expirada. Reconecte em Configurações > Integrações.') unless token

    uri = URI("#{base}#{path}")
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"

    handle_response(http.request(request), path)
  rescue StandardError => e
    Rails.logger.error "Google::AnalyticsInsightsService: GET #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar o Google Analytics.')
  end

  def post(base, path, body)
    token = token_or_error
    return Result.new(success: false, error: 'Sessão do Google expirada. Reconecte em Configurações > Integrações.') unless token

    uri = URI("#{base}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    handle_response(http.request(request), path)
  rescue StandardError => e
    Rails.logger.error "Google::AnalyticsInsightsService: POST #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar o Google Analytics.')
  end

  def handle_response(response, path)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::AnalyticsInsightsService: #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao consultar o Google Analytics.')
    end

    Result.new(success: true, data: parsed)
  end
end
