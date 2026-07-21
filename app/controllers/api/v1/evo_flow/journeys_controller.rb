class Api::V1::EvoFlow::JourneysController < Api::V1::BaseController
  # ParamsWrapper (JSON, enabled globally by its initializer) MERGES its wrapper
  # into request.request_parameters — the hash this proxy forwards. Keep it off.
  wrap_parameters false

  # An unusable evo-flow config raises while the client is being constructed
  # (before any request leaves the process), so rescue it at class level.
  rescue_from EvoFlow::ConfigurationError, with: :handle_evo_flow_misconfiguration

  # flowData (nodes/edges/variables) can be large; bound what we forward. Depth
  # cap mirrors SegmentsController — a byte cap alone still allows deep nesting.
  MAX_BODY_BYTES = 300_000
  MAX_BODY_DEPTH = 25

  # Rails unescapes the `*path` glob (%2F -> /, %2e -> .) and EvoFlow::Client#join
  # runs URI.join, which resolves `..`: an unfiltered subpath leaves /journeys and
  # reaches any evo-flow endpoint under the service key. `%` is out too, so a
  # double-encoded traversal cannot be smuggled through for evo-flow to decode.
  SAFE_SUBPATH = %r{\A[A-Za-z0-9\-._~/]+\z}

  # EVO-2188 hardening: like SegmentsController (EVO-1938), the proxied endpoints
  # must be gated by permission — otherwise any authenticated user (incl. the
  # default agent) could manage journeys through the API even though the UI hides
  # them. The journeys.* keys already exist in the RBAC catalog. Because this is a
  # single passthrough action, the gate lives in a before_action that maps the
  # HTTP method + subpath to the right permission (see #required_permission_key).
  PERMISSION_KEYS = %w[
    journeys.read journeys.create journeys.update journeys.delete
    journeys.toggle_active journeys.duplicate journeys.manage_sessions
  ].freeze
  PERMISSION_KEYS.each { |key| EvoPermissionConcern.register_permission_key(key) }

  before_action :reject_unsafe_subpath!
  before_action :check_proxy_permission!

  # Generic passthrough to evo-flow's /journeys/* API.
  #
  # The CRM ships a proxy for `segments` (Api::V1::EvoFlow::SegmentsController)
  # but NOT for `journeys`, so the journey builder in the frontend calls
  # /api/v1/journeys* and gets 404/405. The evo-flow backend already exposes the
  # full /api/v1/journeys* surface — this controller forwards the request
  # (method + subpath + query + body) to evo-flow and returns its response
  # verbatim, mirroring how SegmentsController talks to evo-flow.
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
    @client ||= EvoFlow::Client.new
  end

  # evo-flow's own status, not a guessed one: it answers 201 on create AND on
  # duplicate, 204 (empty) on delete.
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

  # Gate the request by the permission that matches the operation. Renders 403 and
  # halts when the user lacks it (check_permission! handles the render).
  #
  # Name is load-bearing: spec/rbac/mutating_actions_gate_guard_spec reflects over
  # check_<action>_permission! to prove the route is gated. Renaming it still
  # gates at runtime, but reads as UNGATED to the guard.
  def check_proxy_permission!
    check_permission!(required_permission_key, :user)
  end

  # Map subpath + HTTP method to a journeys.* permission. The SUBPATH decides
  # first: evo-flow serves sessions under GET/DELETE /journeys/:id/sessions*, so
  # keying off the verb made journeys.manage_sessions unreachable. Otherwise the
  # verb decides, and POST without a subpath is the create. evo-flow still
  # validates server-side.
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

  # The catch-all wildcard captures everything after "journeys/" into
  # params[:path] (nil for the collection route /journeys).
  def build_path
    sub = params[:path].to_s.sub(%r{\A/+}, '')
    sub.empty? ? '/journeys' : "/journeys/#{sub}"
  end

  # Raw JSON body (name, isActive, flowData, flowTriggers, ...), forwarded
  # verbatim. Intentionally NOT run through strong params: nested flowData with
  # empty arrays (nodes: []) gets mangled by `permit`. evo-flow validates it
  # server-side; it is never mass-assigned locally. A bare array arrives wrapped
  # as { "_json" => [...] }; POST /journeys/:id/variables needs it unwrapped.
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

  # Pass evo-flow's body through unchanged under an `errors` key, preserving its
  # HTTP status.
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
