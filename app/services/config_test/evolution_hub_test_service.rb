require 'httparty'

module ConfigTest
  # Validates the EvoCRM <-> Evolution Hub link by hitting GET /api/v1/auth/me
  # on the configured Hub with the configured API key. A 200 response means
  # both the URL and the API key are correct.
  class EvolutionHubTestService
    include HTTParty
    default_timeout 8

    def call
      url     = MetaBaseUrl.hub_url
      api_key = GlobalConfigService.load('EVOLUTION_HUB_API_KEY', nil)

      return { success: false, message: 'EVOLUTION_HUB_API_KEY not configured' } if api_key.blank?

      response = HTTParty.get(
        "#{url.chomp('/')}/api/v1/auth/me",
        headers: {
          'Authorization' => "Bearer #{api_key}",
          'Accept'        => 'application/json'
        },
        timeout: 8
      )

      case response.code
      when 200
        user = response.parsed_response.is_a?(Hash) ? response.parsed_response['user'] : nil
        message = user ? "Conectado como #{user['email']}" : 'Conexão bem-sucedida'
        { success: true, message: message }
      when 401
        { success: false, message: 'API key inválida (401)' }
      when 404
        { success: false, message: 'Endpoint não encontrado — verifique a URL do Hub (404)' }
      else
        { success: false, message: "Resposta inesperada do Hub: HTTP #{response.code}" }
      end
    rescue HTTParty::Error, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      { success: false, message: "Não foi possível alcançar o Hub: #{e.message}" }
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
      { success: false, message: 'Timeout ao conectar ao Hub' }
    rescue StandardError => e
      { success: false, message: "Falha inesperada: #{e.message}" }
    end
  end
end
