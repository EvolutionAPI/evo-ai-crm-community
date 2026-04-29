module EvolutionGoConcern
  extend ActiveSupport::Concern

  private

  def connect_instance(api_url, instance_token, _instance_name = nil)
    connect_url = "#{api_url.chomp('/')}/instance/connect"
    Rails.logger.info "Evolution Go API: Connecting instance at #{connect_url}"

    webhook_url_value = webhook_url

    request_body = {
      subscribe: [
        'MESSAGE',
        'READ_RECEIPT',
        'CONNECTION'
      ],
      webhookUrl: webhook_url_value
    }

    uri = URI.parse(connect_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    Rails.logger.info "Evolution Go API: Connect instance request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Connect instance response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Connect instance response body: #{response.body}"

    raise "Failed to connect instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Connect instance JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API connect instance endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Connect instance connection error: #{e.class} - #{e.message}"
    raise "Failed to connect instance: #{e.message}"
  end

  def webhook_url
    backend_url = ENV['BACKEND_URL'].presence ||
                  GlobalConfigService.load('BACKEND_URL', nil).to_s.strip.presence
    raise 'BACKEND_URL is not configured (required to register Evolution Go webhook callback)' if backend_url.blank?

    "#{backend_url.chomp('/')}/webhooks/whatsapp/evolution_go"
  end
end
