require 'net/http'

# Google::ContactsService — sincronização de Contatos Google, reaproveitando a
# MESMA conexão OAuth "Google Workspace" usada por GTM/GA4/YouTube/Calendário
# (Integrations::Hook(app_id: 'google_workspace')) — só faltava o escopo
# `contacts` (ver Integrations::App#build_google_workspace_action) e este
# serviço pra consumir a People API. Sem app OAuth nem redirect_uri separados.
class Google::ContactsService
  TOKEN_URL = 'https://oauth2.googleapis.com/token'
  BASE_URL = 'https://people.googleapis.com/v1'
  PERSON_FIELDS = 'names,phoneNumbers,emailAddresses'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_workspace')
  end

  def connected?
    @hook&.settings&.dig('refresh_token').present? && @hook.settings['scope'].to_s.include?('/auth/contacts')
  end

  # Lista todos os contatos do Google (paginado — a People API devolve no
  # máximo 1000 por página). Normaliza pra {resource_name, name, phone, email}
  # com o telefone já em E.164-ish (só dígitos +, sem espaço/parênteses) pra
  # comparar direto com Contact#phone_number.
  def list_contacts
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    contacts = []
    page_token = nil

    loop do
      params = { personFields: PERSON_FIELDS, pageSize: 1000 }
      params[:pageToken] = page_token if page_token.present?

      result = get('/people/me/connections', token, params)
      return result unless result.success

      (result.data['connections'] || []).each do |person|
        contacts << normalize_person(person)
      end

      page_token = result.data['nextPageToken']
      break if page_token.blank? || contacts.size >= 5000
    end

    Result.new(success: true, data: contacts)
  end

  def create_contact(name:, phone: nil, email: nil)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    body = {
      names: [{ givenName: name }],
      phoneNumbers: phone.present? ? [{ value: phone }] : [],
      emailAddresses: email.present? ? [{ value: email }] : []
    }

    post('/people:createContact', token, body)
  end

  private

  def normalize_person(person)
    name = person.dig('names', 0, 'displayName')
    phone_raw = person.dig('phoneNumbers', 0, 'canonicalForm') || person.dig('phoneNumbers', 0, 'value')
    email = person.dig('emailAddresses', 0, 'value')

    {
      resource_name: person['resourceName'],
      name: name,
      phone: phone_raw.present? ? phone_raw.gsub(/[^\d+]/, '') : nil,
      email: email
    }
  end

  def not_connected_message
    'Conecte (ou reconecte) o Google em Configurações > Integrações > Google Workspace — precisa aceitar o escopo de Contatos.'
  end

  def access_token
    return nil unless connected?

    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'grant_type' => 'refresh_token',
                                      'client_id' => GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil),
                                      'client_secret' => GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_SECRET', nil),
                                      'refresh_token' => @hook.settings['refresh_token']
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)['access_token']
  rescue StandardError => e
    Rails.logger.error "Google::ContactsService: token refresh error: #{e.message}"
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
      Rails.logger.error "Google::ContactsService: #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao consultar o Google Contatos.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Google::ContactsService: error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar o Google Contatos.')
  end
end
