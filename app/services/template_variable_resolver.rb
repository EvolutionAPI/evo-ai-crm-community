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
  SEGMENT_FORMAT = /\A[a-z][a-z0-9_]*\z/i
  # public_send on user-supplied paths needs a perimeter: reader methods only.
  DENIED_SEGMENTS = %w[
    destroy delete delete_all update update_all save touch send public_send
    instance_variable_get instance_eval class_eval method tap then yield_self
  ].freeze

  ROOTS = %w[contact conversation pipeline].freeze

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
    source = root_object(root)

    segments.reduce(source) do |current, segment|
      return nil if current.blank?
      next nil unless safe_segment?(segment)

      read_segment(current, segment)
    end
  end

  private

  def root_object(root)
    case root
    when 'contact' then @conversation.contact
    when 'conversation' then @conversation
    when 'pipeline' then @conversation.pipeline_items.order(created_at: :desc).first
    end
  end

  def safe_segment?(segment)
    segment.match?(SEGMENT_FORMAT) && DENIED_SEGMENTS.exclude?(segment)
  end

  def read_segment(current, segment)
    if current.respond_to?(segment) && current.method(segment).arity.between?(-1, 0)
      current.public_send(segment)
    elsif current.respond_to?(:[])
      current[segment] || current[segment.to_sym]
    end
  end
end
