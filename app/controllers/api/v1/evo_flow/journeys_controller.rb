class Api::V1::EvoFlow::JourneysController < Api::V1::BaseController
  # An unusable evo-flow config raises while the client is being constructed
  # (before any request leaves the process), so rescue it at class level.
  rescue_from EvoFlow::ConfigurationError, with: :handle_evo_flow_misconfiguration

  # flowData (nodes/edges/variables) can be large; bound what we forward.
  MAX_BODY_BYTES = 300_000

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

  before_action :authorize_journeys!

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

    if body && body.to_json.bytesize > MAX_BODY_BYTES
      return render json: { errors: { message: 'Journey payload is too large' } },
                    status: :payload_too_large
    end

    result =
      case request.request_method_symbol
      when :get    then client.get(ef_path, request.query_parameters)
      when :post   then client.post(ef_path, body || {})
      when :put    then client.put(ef_path, body || {})
      when :patch  then client.patch(ef_path, body || {})
      when :delete then client.delete(ef_path)
      else return head(:method_not_allowed)
      end

    render json: result, status: success_status
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  private

  def client
    @client ||= EvoFlow::Client.new
  end

  # Gate the request by the permission that matches the operation. Renders 403 and
  # halts when the user lacks it (check_permission! handles the render).
  def authorize_journeys!
    check_permission!(required_permission_key, :user)
  end

  # Map HTTP method + subpath to a journeys.* permission. Best-effort but safe:
  # reads require journeys.read; deletes require journeys.delete; special subpaths
  # (toggle-active/duplicate/sessions) require their specific permission; a create
  # (POST /journeys) requires journeys.create; every other write requires
  # journeys.update. evo-flow still validates server-side.
  def required_permission_key
    method = request.request_method_symbol
    sub = params[:path].to_s.downcase

    return 'journeys.read' if method == :get
    return 'journeys.delete' if method == :delete
    return 'journeys.toggle_active' if sub.include?('toggle') || sub.include?('active')
    return 'journeys.duplicate' if sub.include?('duplicate')
    return 'journeys.manage_sessions' if sub.include?('session')
    return 'journeys.create' if method == :post && params[:path].blank?

    'journeys.update'
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
  # server-side; it is never mass-assigned locally.
  def request_body
    return nil unless request.request_method_symbol.in?(%i[post put patch])

    rp = request.request_parameters
    rp.respond_to?(:to_unsafe_h) ? rp.to_unsafe_h : rp
  end

  # Create (POST /journeys, no subpath) -> 201; everything else -> 200.
  def success_status
    request.post? && params[:path].blank? ? :created : :ok
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
