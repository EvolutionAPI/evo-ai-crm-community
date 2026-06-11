class TemplateVariableResolver
  # Resolves {{root.path}} placeholders inside template variable values against
  # a conversation's live records. Shared by the Automation Rules executors
  # (AutomationRules::MessageActionHandlers) and Messages::MessageBuilder, so
  # the modal flow, the canvas flow and the evo-flow journey runtime all render
  # variables through one engine (EVO-1267 / story 10.19).
  #
  # Contract: an unresolvable path yields '' (never raises); a blank resolution
  # falls back to the per-variable fallback when one is provided.
  PATH_PATTERN = /\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/

  # Default-deny allowlist of the exact dotted tails resolvable under each root.
  # Mirrors the curated SOURCE_FIELD_PATHS the Send Message panel exposes — the
  # only legitimate variable sources — plus pipeline_stage_id. Anything outside
  # this set resolves to '': association traversal into channel credentials
  # ({{conversation.inbox.channel.provider_config}}, page_access_token, the
  # Sendgrid Fernet-decrypting api_key reader), mass-dump readers (attributes,
  # to_json, as_json, serializable_hash, inspect) and arbitrary getters are all
  # off the legitimate surface. The allowlist — not a denylist — is the
  # perimeter: a denylist is blind to readers and cannot be completed
  # (EVO-1267 review B1). Reachable end-to-end via the Custom expression field,
  # which ships raw paths, so the gate lives here on the resolution side.
  ALLOWED_PATHS = {
    'contact' => %w[name email phone_number identifier].freeze,
    'conversation' => %w[display_id status pipeline_stage_id].freeze,
    'pipeline' => %w[pipeline_stage_id entered_at pipeline_stage.name pipeline.name].freeze
  }.freeze

  ROOTS = ALLOWED_PATHS.keys.freeze

  def initialize(conversation)
    @conversation = conversation
  end

  def resolve_params(processed_params, fallbacks = nil)
    return processed_params unless processed_params.is_a?(Hash)

    fallbacks = fallbacks.is_a?(Hash) ? fallbacks : {}
    processed_params.to_h do |key, value|
      resolved = resolve_value(value)
      resolved = fallbacks[key].to_s if resolved.blank? && fallbacks[key].present?
      [key, resolved]
    end
  end

  def resolve_value(value)
    return value unless value.is_a?(String)

    value.gsub(PATH_PATTERN) do
      resolved = resolve_path(Regexp.last_match(1))
      resolved.nil? ? '' : resolved.to_s
    end
  end

  def resolve_path(path)
    root, *segments = path.split('.')
    return nil unless ALLOWED_PATHS[root]&.include?(segments.join('.'))

    segments.reduce(root_object(root)) do |current, segment|
      return nil if current.blank?

      read_segment(current, segment)
    end
  end

  private

  # Memoized per resolver instance: several {{pipeline.x}} placeholders in one
  # render must not refire the pipeline_items query.
  def root_object(root)
    return @root_objects[root] if (@root_objects ||= {}).key?(root)

    @root_objects[root] =
      case root
      when 'contact' then @conversation.contact
      when 'conversation' then @conversation
      when 'pipeline' then @conversation.pipeline_items.order(created_at: :desc).first
      end
  end

  # Defence in depth behind the allowlist: even though every reachable segment
  # is allowlisted, only invoke zero-arg readers — never anything that could
  # carry a side effect.
  def read_segment(current, segment)
    if current.respond_to?(segment) && current.method(segment).arity.between?(-1, 0)
      current.public_send(segment)
    elsif current.respond_to?(:[])
      current[segment] || current[segment.to_sym]
    end
  end
end
