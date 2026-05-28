class Api::V1::EvoFlow::SegmentsController < Api::V1::BaseController
  # Bound the opaque definition we forward to evo-flow (it is passed through with
  # to_unsafe_h, so without a cap a client could amplify an arbitrarily
  # large/deep payload against evo-flow).
  MAX_DEFINITION_BYTES = 100_000
  MAX_DEFINITION_DEPTH = 25

  before_action :guard_definition_payload, only: %i[create update preview]

  # GET /api/v1/segments
  def index
    render json: client.get('/segments', list_params), status: :ok
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  # GET /api/v1/segments/:id
  def show
    render json: client.get("/segments/#{params[:id]}"), status: :ok
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  # POST /api/v1/segments
  def create
    render json: client.post('/segments', segment_payload), status: :created
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  # PUT /api/v1/segments/:id
  def update
    render json: client.put("/segments/#{params[:id]}", segment_payload), status: :ok
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  # POST /api/v1/segments/preview
  def preview
    render json: client.post('/segments/preview', { definition: preview_definition }), status: :ok
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  private

  def client
    @client ||= EvoFlow::Client.new
  end

  def list_params
    params.permit(:page, :limit, :search, :status).to_h
  end

  def segment_payload
    {
      name: params[:name],
      definition: definition_hash(params[:definition]),
      status: params[:status]
    }.compact
  end

  def preview_definition
    definition_hash(params.require(:definition))
  end

  # `definition` is an opaque DSL blob forwarded verbatim to evo-flow (which
  # validates it server-side). We deliberately do NOT run it through nested
  # strong-params: `permit(definition: {})` mangles the payload (e.g. silently
  # drops empty arrays like `nodes: []`). It is never mass-assigned locally.
  def definition_hash(definition)
    definition.respond_to?(:to_unsafe_h) ? definition.to_unsafe_h : definition
  end

  def guard_definition_payload
    raw = params[:definition]
    return if raw.blank?

    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
    return if within_payload_limits?(hash)

    render json: { errors: { message: 'Segment definition is too large or too deeply nested' } },
           status: :payload_too_large
  end

  def within_payload_limits?(hash)
    hash.to_json.bytesize <= MAX_DEFINITION_BYTES && structure_depth(hash) <= MAX_DEFINITION_DEPTH
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
  # HTTP status. No re-shaping, no message swallowing.
  def handle_evo_flow_error(error)
    body = error.response&.parsed_response || { message: error.message }
    render json: { errors: body }, status: (error.code || :bad_gateway)
  end
end
