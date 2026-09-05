class Api::V1::EvoFlow::JourneysController < Api::V1::BaseController
  include EvoFlowTenantPassthrough

  # ParamsWrapper MERGES its wrapper into request.request_parameters — the hash
  # this proxy forwards.
  wrap_parameters false

  rescue_from EvoFlow::ConfigurationError, with: :handle_evo_flow_misconfiguration

  MAX_BODY_BYTES = 300_000
  MAX_BODY_DEPTH = 25

  # Rails unescapes the glob (%2F -> /, %2e -> .) and Client#join runs URI.join,
  # which resolves `..`: an unfiltered subpath leaves /journeys and reaches any
  # evo-flow endpoint under the service key.
  SAFE_SUBPATH = %r{\A[A-Za-z0-9\-._~/]+\z}

  PERMISSION_KEYS = %w[
    journeys.read journeys.create journeys.update journeys.delete
    journeys.toggle_active journeys.duplicate journeys.manage_sessions
  ].freeze
  PERMISSION_KEYS.each { |key| EvoPermissionConcern.register_permission_key(key) }

  before_action :reject_unsafe_subpath!
  before_action :check_proxy_permission!

  # Forwards method + subpath + query + body to evo-flow's /journeys* surface and
  # returns its response verbatim, like SegmentsController does for /segments.
  def proxy
    ef_path = build_path
    body = request_body

    return if body && !guard_body_payload(body)

    status, result =
      case request.request_method_symbol
      when :get, :head then client.request(:get, ef_path, query: request.query_parameters)
      when :post       then client.request(:post, ef_path, payload: body || {})
      when :put        then client.request(:put, ef_path, payload: body || {})
      when :patch      then client.request(:patch, ef_path, payload: body || {})
      when :delete     then client.request(:delete, ef_path)
      else return head(:method_not_allowed)
      end

    relay(status, result)
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  private

  def client
    @client ||= EvoFlow::Client.new(extra_headers: evo_flow_passthrough_headers)
  end

  # evo-flow's own status, not a guessed one: 201 on create AND duplicate, 204 on delete.
  def relay(status, result)
    return head(:no_content) if status == 204 || result.nil?

    render json: result, status: status
  end

  def reject_unsafe_subpath!
    sub = params[:path].to_s
    return if sub.blank?
    return if sub.match?(SAFE_SUBPATH) && sub.split('/').none? { |segment| segment == '..' }

    render json: { errors: { message: 'Invalid journeys path' } }, status: :bad_request
  end

  # Name is load-bearing: spec/rbac/mutating_actions_gate_guard_spec reflects over
  # check_<action>_permission! to prove the route is gated.
  def check_proxy_permission!
    check_permission!(required_permission_key, :user)
  end

  # Subpath decides before the verb: evo-flow serves sessions under
  # GET/DELETE /journeys/:id/sessions*, so keying off the verb made
  # journeys.manage_sessions unreachable.
  def required_permission_key
    sub = params[:path].to_s.downcase

    return 'journeys.manage_sessions' if sub.include?('session')
    return 'journeys.toggle_active' if sub.include?('toggle-active')
    return 'journeys.duplicate' if sub.include?('duplicate')

    case request.request_method_symbol
    when :get, :head then 'journeys.read'
    when :delete     then 'journeys.delete'
    when :post       then sub.empty? ? 'journeys.create' : 'journeys.update'
    else 'journeys.update'
    end
  end

  def build_path
    sub = params[:path].to_s.sub(%r{\A/+}, '')
    sub.empty? ? '/journeys' : "/journeys/#{sub}"
  end

  # Deliberately not strong params: `permit` mangles nested flowData (drops
  # `nodes: []`). A bare array arrives as { "_json" => [...] } and
  # POST /journeys/:id/variables needs it unwrapped.
  def request_body
    return nil unless request.request_method_symbol.in?(%i[post put patch])

    rp = request.request_parameters
    rp = rp.to_unsafe_h if rp.respond_to?(:to_unsafe_h)
    rp.is_a?(Hash) && rp.keys == ['_json'] ? rp['_json'] : rp
  end

  def guard_body_payload(body)
    return true if body.to_json.bytesize <= MAX_BODY_BYTES && structure_depth(body) <= MAX_BODY_DEPTH

    render json: { errors: { message: 'Journey payload is too large or too deeply nested' } },
           status: :payload_too_large
    false
  end

  def structure_depth(obj)
    case obj
    when Hash
      obj.empty? ? 1 : 1 + obj.values.map { |v| structure_depth(v) }.max
    when Array
      obj.empty? ? 1 : 1 + obj.map { |v| structure_depth(v) }.max
    else
      0
    end
  end

  def handle_evo_flow_error(error)
    body = error.response&.parsed_response || { message: error.message }
    render json: { errors: body }, status: (error.code || :bad_gateway)
  end

  # 503, not 500: the integration was never configured on this deployment.
  def handle_evo_flow_misconfiguration(error)
    Rails.logger.error("evo-flow integration is not configured: #{error.message}")
    error_response(
      ApiErrorCodes::SERVICE_UNAVAILABLE,
      'Journeys are unavailable: the evo-flow integration is not configured on this deployment',
      status: :service_unavailable
    )
  end
end
