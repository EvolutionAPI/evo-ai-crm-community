class Api::V1::EvoFlow::JourneysController < Api::V1::BaseController
  # config/initializers/wrap_parameters.rb turns ActionController::ParamsWrapper
  # on for every JSON request, and it MERGES its wrapper into
  # request.request_parameters — the exact hash this proxy forwards. So a
  # `{name, flowData}` body reached evo-flow as
  # `{name, flowData, journey: {name, flowData}}`. evo-flow only tolerates it
  # because its ValidationPipe runs forbidNonWhitelisted: false ("temporário",
  # per its main.ts); flipping that to the secure default would 400 every
  # create/update coming through here. It also breaks the bare-array body of
  # POST /journeys/:id/variables, whose `_json` envelope stops being the only
  # key once the wrapper is merged in. A passthrough must forward the body it
  # was given, nothing else.
  wrap_parameters false

  # An unusable evo-flow config raises while the client is being constructed
  # (before any request leaves the process), so rescue it at class level.
  rescue_from EvoFlow::ConfigurationError, with: :handle_evo_flow_misconfiguration

  # flowData (nodes/edges/variables) can be large; bound what we forward. The
  # depth cap mirrors SegmentsController: a byte cap alone still lets a small
  # payload amplify into deep recursion on the evo-flow side.
  MAX_BODY_BYTES = 300_000
  MAX_BODY_DEPTH = 25

  # `*path` is a raw glob: Rails unescapes it (%2F -> /, %2e -> .) before we see
  # it, and EvoFlow::Client#join runs URI.join, which resolves `..` per RFC 3986.
  # So an unchecked "j1/../../segments" would leave the /journeys prefix and
  # reach ANY evo-flow endpoint carrying the service integration key — a caller
  # holding only journeys.read could read segments/campaigns. Restrict the
  # subpath to the shape evo-flow actually routes (UUIDs and ASCII slugs) and
  # reject `..` outright; `%` is excluded so double-encoding cannot smuggle a
  # traversal past us for evo-flow's own router to decode.
  SAFE_SUBPATH = %r{\A[A-Za-z0-9\-._~/]+\z}

  # EVO-2188 hardening: like SegmentsController (EVO-1938), the proxied endpoints
  # must be gated by permission — otherwise any authenticated user (incl. the
  # default agent) could manage journeys through the API even though the UI hides
  # them. The journeys.* keys already exist in the RBAC catalog. Because this is a
  # single passthrough action, the gate lives in a before_action that maps the
  # HTTP method + subpath to the right permission (see #required_permission_key).
  #
  # The filter is named check_<action>_permission! on purpose: that is the shape
  # require_permissions generates, and spec/rbac/mutating_actions_gate_guard_spec
  # reflects over it to prove every routed mutating action is gated. A
  # differently-named filter gates at runtime but reads as UNGATED to the guard.
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

  # Relay evo-flow's own status instead of guessing it: it answers 201 on
  # create AND on duplicate, and 204 (empty) on delete. Rendering everything as
  # 200 broke the "verbatim response" contract this proxy exists to keep.
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
  def check_proxy_permission!
    check_permission!(required_permission_key, :user)
  end

  # Map HTTP method + subpath to a journeys.* permission.
  #
  # The SUBPATH is matched FIRST, because the sub-resources are what the
  # dedicated permissions exist for: evo-flow serves sessions under
  # GET/DELETE /journeys/:id/sessions*, so keying off the verb first made
  # journeys.manage_sessions unreachable (reads fell to journeys.read, and
  # deleting a single session or bulk-deleting them fell to journeys.delete).
  # Only once no sub-resource matches does the verb decide: GET/HEAD ->
  # journeys.read, DELETE -> journeys.delete, POST /journeys (no subpath) ->
  # journeys.create, every other write -> journeys.update. evo-flow still
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
  # server-side; it is never mass-assigned locally.
  #
  # Rails wraps a top-level JSON ARRAY body as { "_json" => [...] }; evo-flow's
  # POST /journeys/:id/variables takes a bare array, so unwrap it or the proxy
  # would hand it an object it cannot bind.
  def request_body
    return nil unless request.request_method_symbol.in?(%i[post put patch])

    rp = request.request_parameters
    rp = rp.to_unsafe_h if rp.respond_to?(:to_unsafe_h)
    rp.is_a?(Hash) && rp.keys == ['_json'] ? rp['_json'] : rp
  end

  # Renders 413 and returns false when the payload is over the size or nesting
  # cap; true when it is safe to forward.
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
