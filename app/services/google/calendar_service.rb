require 'net/http'

# Google::CalendarService — conecta com o Google Calendar (agenda "primary"
# da conta que fez login) usando GOOGLE_CALENDAR_CLIENT_ID/SECRET (já
# configurados em Configurações > Admin > Integrações — só faltava o fluxo
# de login/uso de verdade). Credencial própria em
# Integrations::Hook(app_id: 'google_calendar'), separada do
# 'google_workspace' (GTM/GA4/YouTube) — apps OAuth diferentes no Google
# Cloud Console, cada um com seu redirect_uri.
class Google::CalendarService
  TOKEN_URL = 'https://oauth2.googleapis.com/token'
  BASE_URL = 'https://www.googleapis.com/calendar/v3'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_calendar')
  end

  def connected?
    @hook&.settings&.dig('refresh_token').present?
  end

  def list_events(time_min:, time_max:)
    token = access_token
    return Result.new(success: false, error: 'Falha ao autenticar com o Google Calendar. Reconecte em Configurações.') unless token

    get('/calendars/primary/events', token, {
          timeMin: time_min, timeMax: time_max, singleEvents: true, orderBy: 'startTime', maxResults: 250
        })
  end

  def create_event(summary:, start_time:, end_time:, description: nil, all_day: false)
    token = access_token
    return Result.new(success: false, error: 'Falha ao autenticar com o Google Calendar. Reconecte em Configurações.') unless token

    body = {
      summary: summary,
      description: description,
      start: all_day ? { date: start_time } : { dateTime: start_time, timeZone: 'America/Sao_Paulo' },
      end: all_day ? { date: end_time } : { dateTime: end_time, timeZone: 'America/Sao_Paulo' }
    }.compact

    post('/calendars/primary/events', token, body)
  end

  private

  def access_token
    settings = @hook&.settings
    return nil if settings.blank? || settings['refresh_token'].blank?

    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'grant_type' => 'refresh_token',
                                      'client_id' => GlobalConfigService.load('GOOGLE_CALENDAR_CLIENT_ID', nil),
                                      'client_secret' => GlobalConfigService.load('GOOGLE_CALENDAR_CLIENT_SECRET', nil),
                                      'refresh_token' => settings['refresh_token']
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)['access_token']
  rescue StandardError => e
    Rails.logger.error "Google::CalendarService: token refresh error: #{e.message}"
    nil
  end

  def get(path, token, params)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"

    handle(http.request(request))
  end

  def post(path, token, body)
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    handle(http.request(request))
  end

  def handle(response)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::CalendarService: #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao consultar o Google Calendar.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Google::CalendarService: error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar o Google Calendar.')
  end
end
