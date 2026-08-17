module LabelConcern
  def create
    model.update_labels(resolve_label_titles(incoming_label_tokens))
    @labels = model.label_list
    render json: { payload: @labels }
  end

  def index
    @labels = model.label_list
    render json: { payload: @labels }
  end

  private

  # EVO-1928: `#create` historically only honoured `labels` shaped as a flat
  # array of strings (`params.permit(labels: [])`). Any other shape made
  # `permitted_params[:labels]` come back `nil`, so `update_labels(nil)` reset
  # the list and replied `200` with no tagging persisted — a false-success.
  # That is precisely the add-label/remove-label journey path, whose evo-flow
  # node posts the label by NAME under a singular key (`labelId`/`label`) and
  # may send a bare scalar instead of an array. Accept those shapes and
  # normalise to an array of non-blank string tokens so the caller's intent
  # always becomes a real tagging.
  def incoming_label_tokens
    raw = permitted_params[:labels]
    raw = singular_label_token if raw.blank?

    Array(raw).map { |value| value.to_s.strip }.reject(&:blank?)
  end

  # Fallback for callers that pass a single label under a singular key rather
  # than the canonical `labels` array. `params.permit` here keeps the input
  # filtered (scalar string only).
  def singular_label_token
    params.permit(:labels, :labelId, :label, :title)
          .values_at(:labels, :labelId, :label, :title)
          .compact.first
  end

  # Clients historically sent label identifiers as UUIDs (matching the Label
  # PK exposed by the `/labels` endpoint). `acts_as_taggable_on :labels`
  # stores whatever string it receives as `tags.name`, so passing UUIDs caused
  # two downstream problems: activity messages rendered UUIDs instead of
  # human-readable titles, and `filter_service#tag_filter_query` (which
  # compares against `tags.name`) could not match on the user-configured
  # title. Translate UUID-shaped inputs to titles here; leave other strings
  # untouched for back-compat with any caller that already sends titles.
  #
  # EVO-1897 (D8): a UUID that does NOT resolve to a `Label` row (e.g. a
  # journey/evo-flow caller carrying an id that is absent from the local
  # `labels` table) must NOT be silently dropped. Doing so made
  # `update_labels([])` wipe the list and reply `200` with no tagging
  # persisted — a false-success for add-label/remove-label nodes. Preserve
  # the original token when it cannot be resolved so the caller's intent is
  # always reflected as a real tagging.
  #
  # Blank input passes straight through: `nil` must stay `nil` so callers can
  # tell "sent nothing" from "sent an empty list".
  def resolve_label_titles(labels)
    return labels if labels.blank?

    Labels::TokenResolver.titles_for(labels)
  end
end
