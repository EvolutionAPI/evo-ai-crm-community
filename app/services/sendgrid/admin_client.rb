module Sendgrid
  # Isolated HTTP client for the SendGrid admin API (credential smoke test +
  # event webhook registration). Mirrors app/services/evo_flow/client.rb
  # (HTTParty + custom error + handle_response + redacted logging).
  class AdminClient
    include HTTParty

    DEFAULT_BASE_URL = 'https://api.sendgrid.com/v3'.freeze
    REDACTED_4XX = '[redacted: 4xx body]'.freeze
    MAX_LOGGED_BODY = 500

    # Events forwarded to the CRM webhook (story 9.2 scope).
    WEBHOOK_EVENTS = %w[
      bounce click deferred delivered dropped group_resubscribe
      group_unsubscribe open processed spam_report unsubscribe
    ].freeze

    def initialize(api_key, base_url: ENV.fetch('SENDGRID_API_BASE_URL', DEFAULT_BASE_URL), timeout: 10)
      @api_key = api_key.to_s
      @base_url = base_url
      @timeout = timeout
    end

    # GET /v3/scopes — authentication smoke test. 401/403 means the key is bad;
    # any other non-2xx or a network error means SendGrid could not confirm it.
    def smoke_test!
      response = request(:get, '/scopes')
      return true if success?(response)
      raise InvalidApiKeyError.new('SendGrid API key is invalid', response.code, response) if invalid_key?(response)

      raise ServiceUnavailableError.new(
        "SendGrid smoke test failed: #{response.code} - #{safe_body(response)}", response.code, response
      )
    end

    # PATCH /v3/user/webhooks/event/settings — single event-webhook config per
    # account; enables the CRM callback URL with the scoped event list.
    def upsert_event_webhook!(callback_url:)
      payload = WEBHOOK_EVENTS.each_with_object({ enabled: true, url: callback_url }) do |event, acc|
        acc[event] = true
      end
      response = request(:patch, '/user/webhooks/event/settings', payload)
      return response.parsed_response if success?(response)

      msg = "SendGrid webhook registration failed: #{response.code} - #{safe_body(response)}"
      Rails.logger.error(msg)
      raise ServiceUnavailableError.new(msg, response.code, response)
    end

    private

    def request(verb, path, payload = nil)
      options = { headers: request_headers, timeout: @timeout }
      options[:body] = payload.to_json if payload
      self.class.public_send(verb, "#{@base_url}#{path}", options)
    rescue HTTParty::Error, SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
      raise ServiceUnavailableError.new("SendGrid request failed: #{e.message}", nil, nil)
    end

    def success?(response)
      (200..299).cover?(response.code)
    end

    def invalid_key?(response)
      [401, 403].include?(response.code)
    end

    def request_headers
      { 'Authorization' => "Bearer #{@api_key}", 'Content-Type' => 'application/json' }
    end

    # 4xx bodies can echo the key or input, so the whole 4xx class is redacted;
    # 5xx bodies are length-bounded.
    def safe_body(response)
      return REDACTED_4XX if (400..499).cover?(response.code)

      body = response.body.to_s
      body.length > MAX_LOGGED_BODY ? "#{body[0, MAX_LOGGED_BODY]}... (truncated)" : body
    end
  end
end
