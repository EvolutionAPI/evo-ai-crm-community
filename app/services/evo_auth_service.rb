require 'net/http'
require 'net/http/persistent'
require 'json'
require 'uri'
require 'digest'

class EvoAuthService
  class AuthenticationError < StandardError; end
  class ValidationError < StandardError
    attr_reader :code, :status

    def initialize(message = 'Invalid token', code: ApiErrorCodes::UNAUTHORIZED, status: nil)
      super(message)
      @code = code.presence || ApiErrorCodes::UNAUTHORIZED
      @status = status
    end
  end
  class NetworkError < StandardError; end
  class ParseError < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10
  IDLE_TIMEOUT = 30

  @persistent_clients = {}
  @clients_mutex = Mutex.new

  class << self
    attr_reader :persistent_clients, :clients_mutex
  end

  attr_reader :base_url

  def initialize(base_url = nil)
    @base_url = base_url || ENV.fetch('EVO_AUTH_SERVICE_URL', 'http://localhost:3001')
  end

  # Validate existing token - Primary method for Evolution authentication
  def validate_token(token:, token_type:)
    headers = build_headers(token, token_type)

    response = instrument_remote_call('validate_token', token_type: token_type) do
      post_request('/api/v1/auth/validate', {}, headers)
    end

    data = response&.dig('data')
    return data if data.present?

    if response&.dig('success') == false && response&.dig('error').present?
      raise_validation_error(response)
    end

    raise AuthenticationError, 'Authentication service unavailable'
  rescue ValidationError
    raise
  rescue AuthenticationError
    raise
  rescue NetworkError => e
    Rails.logger.error "EvoAuth: Network error during validation: #{e.message}"
    raise AuthenticationError, 'Authentication service unavailable'
  rescue StandardError => e
    Rails.logger.error "EvoAuth: Token validation error: #{e.class} - #{e.message}"
    raise AuthenticationError, 'Token validation failed'
  end

  def build_headers(token, token_type)
    case token_type.to_sym
    when :bearer
      { 'Authorization' => "Bearer #{token}" }
    when :api_access_token
      { 'api_access_token' => token }
    else
      raise ArgumentError, "Invalid token type: #{token_type}"
    end
  end

  # Get user data by ID
  def get_user(user_id)
    response = get_request("/api/v1/users/#{user_id}")
    response&.dig('data')
  rescue StandardError => e
    Rails.logger.error "EvoAuth: Get user error: #{e.message}"
    nil
  end

  # Authorization checks below are SERVER-TO-SERVER: they ask "does user X hold
  # permission K?" — they must NOT ride the caller's (rotating) bearer. Forwarding
  # the user bearer means a token rotated/revoked mid-request makes auth raise on
  # the sub-call (returns 500), the callers below rescue it as a denial, and the
  # user gets a SPURIOUS 403 on a permission they actually hold (works again after
  # re-login). The service token is stable AND sets Current.service_authenticated
  # in auth, which bypasses the per-caller `users.read` gate on check_permission.
  def service_auth_headers
    token = ENV['EVOAI_CRM_API_TOKEN'].presence
    token ? { 'X-Service-Token' => token } : {}
  end

  # Server-to-server permission check. Optional `scope_id` scopes the resolution
  # to a single account: without it, the auth resolves across the union of the
  # user's roles (single-tenant behaviour, byte-for-byte compatible); with it,
  # an auth that supports per-account scoping filters the resolution to that
  # account, and one that doesn't simply ignores the parameter.
  def check_user_permission(user_id, permission_key, scope_id: nil)
    payload = { permission_key: permission_key }
    payload[:scope_id] = scope_id if scope_id.present?

    response = instrument_remote_call('check_user_permission', user_id: user_id) do
      post_request("/api/v1/users/#{user_id}/check_permission",
                   payload,
                   service_auth_headers)
    end

    data = response['data'] || {}
    if data&.dig('has_permission')
      true
    else
      Rails.logger.error "Failed to check user permission: #{response&.dig('error') || 'Unknown error'}"
      false
    end
  rescue StandardError => e
    Rails.logger.error "Error checking user permission: #{e.message}"
    false
  end

  # Lists the caller's own permission keys from the auth-service
  # (GET /api/v1/permissions). The call authenticates AS the user via their
  # bearer token — the auth resolves `current_user.permissions`, so no user id
  # is passed. Optional `scope_id` narrows the resolution to a single account:
  # an auth that supports per-account scoping filters to that account; an auth
  # that doesn't ignores the parameter and returns the global list, so the
  # method is behaviour-flat when unscoped. Fail-soft: any error yields [].
  def list_user_permissions(bearer_token, scope_id: nil)
    endpoint = '/api/v1/permissions'
    endpoint += "?scope_id=#{URI.encode_www_form_component(scope_id.to_s)}" if scope_id.present?
    headers = bearer_token.present? ? { 'Authorization' => bearer_token } : {}

    response = instrument_remote_call('list_user_permissions', scope_id: scope_id) do
      get_request(endpoint, headers)
    end

    data = response['data'] || {}
    Array(data['permissions'])
  rescue StandardError => e
    Rails.logger.error "Error listing user permissions: #{e.message}"
    []
  end

  # Get user role
  def get_role(user_id, _identifier = nil)
    # Use new standard: /api/v1/users/:id/role
    headers = {}
    response = instrument_remote_call('get_role', user_id: user_id) do
      get_request("/api/v1/users/#{user_id}/role", headers)
    end
    data = response['data'] || {}
    data&.dig('role')
  rescue StandardError => e
    Rails.logger.error "EvoAuth: Get role error: #{e.message}"
    nil
  end

  private

  def get_request(endpoint, headers = {})
    uri = URI.join(@base_url, endpoint)
    request = Net::HTTP::Get.new(uri)
    request['Content-Type'] = 'application/json'
    apply_headers(request, headers)
    perform_request(uri, request)
  end

  def post_request(endpoint, payload, headers = {})
    uri = URI.join(@base_url, endpoint)
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    apply_headers(request, headers)
    request.body = payload.to_json
    perform_request(uri, request)
  end

  def apply_headers(request, headers)
    headers.each do |key, value|
      request[key] = value
    end

    # An explicit auth header — including a service token (X-Service-Token /
    # X-Internal-API-Token) — means the caller already chose its credential, so we
    # must NOT co-inject the request's user bearer on top of it. Auth checks the
    # Authorization header FIRST, so a co-injected (possibly rotated/revoked) bearer
    # would shadow the service token and the call would fail-closed (see
    # check_user_permission). Treat any of these keys as "auth already provided".
    auth_already_provided = headers.key?('Authorization') ||
                            headers.key?('api_access_token') ||
                            headers.key?('X-Service-Token') ||
                            headers.key?('X-Internal-API-Token')
    unless auth_already_provided
      request['Authorization'] = "Bearer #{Current.bearer_token}" if Current.bearer_token.present?
      request['api_access_token'] = Current.api_access_token.to_s if Current.api_access_token.present?
    end
  end

  def perform_request(uri, request)
    response = persistent_http_client.request(uri, request)
    parsed = parse_response_body!(response.body)
    return parsed if response.is_a?(Net::HTTPSuccess)

    status = response.code.to_i
    if validation_status?(status)
      raise_validation_error(parsed, status: status)
    end

    Rails.logger.error "EvoAuth: HTTP error #{response.code}: #{response.message}"
    raise NetworkError, "HTTP #{response.code}: #{response.message}"
  rescue ValidationError => e
    raise e
  rescue ParseError => e
    Rails.logger.error "EvoAuth: Response parse error: #{e.message}"
    raise NetworkError, "Invalid response format"
  rescue Timeout::Error, Net::ReadTimeout, Net::OpenTimeout => e
    Rails.logger.error "EvoAuth: Request timeout: #{e.class} - #{e.message}"
    raise NetworkError, "Request timeout: #{e.message}"
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT => e
    Rails.logger.error "EvoAuth: Connection error: #{e.class} - #{e.message}"
    raise NetworkError, "Connection failed: #{e.message}"
  rescue SocketError => e
    Rails.logger.error "EvoAuth: Socket error: #{e.class} - #{e.message}"
    raise NetworkError, "Socket error: #{e.message}"
  rescue OpenSSL::SSL::SSLError => e
    Rails.logger.error "EvoAuth: SSL error: #{e.class} - #{e.message}"
    raise NetworkError, "SSL error: #{e.message}"
  rescue NetworkError => e
    raise e
  rescue StandardError => e
    Rails.logger.error "EvoAuth: Unexpected error: #{e.class} - #{e.message}"
    raise NetworkError, "Unexpected error: #{e.message}"
  end

  def persistent_http_client
    self.class.clients_mutex.synchronize do
      self.class.persistent_clients[@base_url] ||= begin
        client = Net::HTTP::Persistent.new(name: "evo-auth-#{Digest::SHA1.hexdigest(@base_url)}")
        client.open_timeout = OPEN_TIMEOUT
        client.read_timeout = READ_TIMEOUT
        client.idle_timeout = IDLE_TIMEOUT
        if Rails.env.development? || @base_url.include?('ngrok')
          client.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
        client
      end
    end
  end

  def instrument_remote_call(operation, metadata = {})
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
    Rails.logger.info("EvoAuthPerformance operation=#{operation} status=ok duration_ms=#{elapsed_ms} #{metadata.map { |k, v| "#{k}=#{v}" }.join(' ')}".strip)
    result
  rescue StandardError => e
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
    Rails.logger.warn("EvoAuthPerformance operation=#{operation} status=error duration_ms=#{elapsed_ms} error=#{e.class} #{metadata.map { |k, v| "#{k}=#{v}" }.join(' ')}".strip)
    raise e
  end

  def parse_response_body!(body)
    return {} if body.blank?

    JSON.parse(body)
  rescue JSON::ParserError => e
    raise ParseError, e.message
  end

  def validation_status?(status)
    [401, 403, 422].include?(status)
  end

  def raise_validation_error(response, status: nil)
    error_payload = response&.dig('error')
    if error_payload.is_a?(Hash)
      error_code = error_payload['code'].presence || default_validation_code_for_status(status)
      error_message = error_payload['message'] || 'Invalid token'
      raise ValidationError.new(error_message, code: error_code, status: status)
    end

    error_message = response&.dig('message') || response&.dig('error') || 'Invalid token'
    raise ValidationError.new(error_message, code: default_validation_code_for_status(status), status: status)
  end

  def default_validation_code_for_status(status)
    case status.to_i
    when 403
      ApiErrorCodes::FORBIDDEN
    when 422
      ApiErrorCodes::VALIDATION_ERROR
    else
      ApiErrorCodes::UNAUTHORIZED
    end
  end
end
