module EvoFlow
  # Raised on any non-2xx evo-flow response, an unparseable body, or a network
  # failure. Mirrors Crm::Hubspot::Api::BaseClient::ApiError (code + response).
  class HTTPError < StandardError
    attr_reader :code, :response

    def initialize(message = nil, code = nil, response = nil)
      @code = code
      @response = response
      super(message)
    end
  end

  # Raised at construction time for an unusable configuration (missing key,
  # invalid scheme, or cleartext transport in production). Fails fast instead
  # of emitting a request that is guaranteed to 401 or that leaks the shared
  # key over cleartext.
  class ConfigurationError < StandardError; end

  # Instance-based (DI-friendly) authenticated HTTP client for evo-flow.
  # Pattern mirrors app/services/crm/hubspot/api/base_client.rb (HTTParty +
  # custom error + handle_response).
  class Client
    include HTTParty

    DEFAULT_API_URL = 'http://evo-flow:3000/api/v1'.freeze
    REDACTED_4XX = '[redacted: 4xx body]'.freeze
    MAX_LOGGED_BODY = 500
    VALID_SCHEMES = %w[http https].freeze
    # Accepted truthy values for EVO_FLOW_ALLOW_INSECURE (case-insensitive).
    INSECURE_TRUTHY = %w[true 1 yes on].freeze

    def initialize(api_url: ENV.fetch('EVO_FLOW_API_URL', DEFAULT_API_URL),
                   api_key: ENV.fetch('AUTH_APIKEY_INTEGRATION_LOCAL', nil),
                   timeout: 10)
      @api_url = api_url
      @api_key = api_key
      @timeout = timeout
      validate_config!
    end

    def post(path, payload)
      response = self.class.post(join(@api_url, path),
                                 body: payload.to_json,
                                 headers: request_headers,
                                 timeout: @timeout)
      handle_response(response)
    # Net::OpenTimeout/Net::ReadTimeout already inherit from Timeout::Error.
    # OpenSSL::SSL::SSLError is its own hierarchy and must be listed explicitly.
    rescue HTTParty::Error, SocketError, Timeout::Error, SystemCallError,
           OpenSSL::SSL::SSLError => e
      raise EvoFlow::HTTPError.new("evo-flow request failed: #{e.message}", nil, nil)
    end

    def get(path, params = {})
      response = self.class.get(join(@api_url, path),
                                query: params.compact,
                                headers: request_headers,
                                timeout: @timeout)
      handle_response(response)
    rescue HTTParty::Error, SocketError, Timeout::Error, SystemCallError,
           OpenSSL::SSL::SSLError => e
      raise EvoFlow::HTTPError.new("evo-flow request failed: #{e.message}", nil, nil)
    end

    def put(path, payload)
      response = self.class.put(join(@api_url, path),
                                body: payload.to_json,
                                headers: request_headers,
                                timeout: @timeout)
      handle_response(response)
    rescue HTTParty::Error, SocketError, Timeout::Error, SystemCallError,
           OpenSSL::SSL::SSLError => e
      raise EvoFlow::HTTPError.new("evo-flow request failed: #{e.message}", nil, nil)
    end

    # Backfill emits events in batches (matches evo-flow BATCH_SIZE=100,
    # TrackBatchEventsDto in src/modules/events/dto/track-batch-events.dto.ts).
    # Stateless: retry is the caller's responsibility (Sidekiq).
    def post_batch(events)
      post('/events/batch', { events: events })
    end

    private

    def validate_config!
      raise ConfigurationError, 'AUTH_APIKEY_INTEGRATION_LOCAL is not set' if @api_key.to_s.strip.empty?

      scheme = URI(@api_url).scheme
      unless VALID_SCHEMES.include?(scheme)
        raise ConfigurationError,
              "EVO_FLOW_API_URL has invalid or missing scheme (#{scheme.inspect}); " \
              "expected one of #{VALID_SCHEMES.inspect}"
      end
      return if scheme == 'https'
      return unless Rails.env.production?
      return if insecure_allowed?

      raise ConfigurationError,
            "refusing to send the API key over cleartext (#{@api_url}); use https " \
            'or set EVO_FLOW_ALLOW_INSECURE=<true|1|yes|on> only on a trusted private network'
    end

    def insecure_allowed?
      INSECURE_TRUTHY.include?(ENV.fetch('EVO_FLOW_ALLOW_INSECURE', '').to_s.downcase)
    end

    # URI.join drops the /api/v1 prefix when path starts with '/' (a leading
    # slash resets to root). A *relative* join (base ends with '/', path has
    # no leading slash) preserves the prefix and normalises the boundary.
    def join(base, path)
      URI.join("#{base.chomp('/')}/", path.to_s.sub(%r{\A/+}, '')).to_s
    end

    def request_headers
      { 'Content-Type' => 'application/json', 'X-Integration-API-Key' => @api_key }
    end

    def handle_response(response)
      raise_api_error(response) unless (200..299).cover?(response.code)

      parse_body(response)
    end

    def parse_body(response)
      response.parsed_response
    rescue JSON::ParserError, TypeError => e
      raise EvoFlow::HTTPError.new("evo-flow returned an unparseable body: #{e.message}",
                                   response.code, response)
    end

    def raise_api_error(response)
      msg = "evo-flow API error: #{response.code} - #{safe_body(response)}"
      Rails.logger.error(msg)
      raise EvoFlow::HTTPError.new(msg, response.code, response)
    end

    # 4xx bodies frequently reflect client input (auth tokens on 401/403,
    # validation echoes on 400/422, etc.), so the whole 4xx class is redacted.
    # 5xx bodies are length-bounded; other classes pass through.
    def safe_body(response)
      return REDACTED_4XX if (400..499).cover?(response.code)

      body = response.body.to_s
      body.length > MAX_LOGGED_BODY ? "#{body[0, MAX_LOGGED_BODY]}... (truncated)" : body
    end
  end
end
