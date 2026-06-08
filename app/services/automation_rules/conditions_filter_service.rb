require 'json'

class AutomationRules::ConditionsFilterService < FilterService
  ATTRIBUTE_MODEL = 'contact_attribute'.freeze

  # Maps frontend attribute_key to the actual key present in changed_attributes.
  # Conversation/Contact dispatch previous_changes directly, so labels (via
  # acts-as-taggable) are stored as `label_list`. Without this alias the
  # attribute_changed filter would never match label transitions.
  ATTRIBUTE_KEY_ALIASES = {
    'labels' => 'label_list'
  }.freeze

  def initialize(rule, conversation = nil, options = {})
    super([], nil)
    @rule = rule
    @conversation = conversation
    # EVO-1642: contact-triggered rules with only-contact conditions run with
    # no conversation in scope; the base relation falls back to the contact.
    @contact = options[:contact]

    # setup filters from json file
    file = File.read('./lib/filters/filter_keys.yml')
    @filters = YAML.safe_load(file)

    @conversation_filters = @filters['conversations']
    @contact_filters = @filters['contacts']
    @message_filters = @filters['messages']

    @options = options
    @changed_attributes = options[:changed_attributes]
  end

  def perform
    return false unless rule_valid?

    @attribute_changed_query_filter = []

    @rule.conditions.each_with_index do |query_hash, current_index|
      @attribute_changed_query_filter << query_hash and next if query_hash['filter_operator'] == 'attribute_changed'

      apply_filter(query_hash, current_index)
    end

    # Remove trailing query operators (and/or) that cause SQL syntax errors
    @query_string = @query_string.strip.gsub(/\s+(and|or)\s*$/i, '')

    records = base_relation.where(@query_string, @filter_values.with_indifferent_access)

    records = perform_attribute_changed_filter(records) if @attribute_changed_query_filter.any?

    matched = records.any?

    Rails.logger.info(
      "[ConditionsFilterService] rule=#{@rule&.id} event=#{@rule&.event_name} matched=#{matched} " \
      "query=#{@query_string.inspect} filter_values=#{@filter_values.inspect} sql=#{records.to_sql rescue 'unavailable'}"
    )

    matched
  rescue StandardError => e
    Rails.logger.error "[ConditionsFilterService] rule=#{@rule&.id} event=#{@rule&.event_name} error=#{e.class}: #{e.message} query=#{@query_string.inspect} filter_values=#{@filter_values.inspect}"
    EvolutionExceptionTracker.new(e).capture_exception
    false
  end

  def rule_valid?
    is_valid = AutomationRules::ConditionValidationService.new(@rule).perform
    Rails.logger.info "Automation rule condition validation failed for rule id: #{@rule.id}" unless is_valid
    @rule.authorization_error! unless is_valid

    is_valid
  end

  def filter_operation(query_hash, current_index)
    if query_hash[:filter_operator] == 'starts_with'
      @filter_values["value_#{current_index}"] = "#{string_filter_values(query_hash)}%"
      like_filter_string(query_hash[:filter_operator], current_index)
    else
      super
    end
  end

  def apply_filter(query_hash, current_index)
    filters = extract_filters(query_hash)
    @query_string += build_query_string(filters, query_hash, current_index)
  end

  # If attribute_changed type filter is present perform this against array
  def perform_attribute_changed_filter(records)
    @attribute_changed_records = []
    current_attribute_changed_record = base_relation
    filter_based_on_attribute_change(records, current_attribute_changed_record)

    @attribute_changed_records.uniq
  end

  # Loop through attribute_changed_query_filter
  def filter_based_on_attribute_change(records, current_attribute_changed_record)
    @attribute_changed_query_filter.each do |filter|
      @changed_attributes = @changed_attributes.with_indifferent_access
      backend_key = ATTRIBUTE_KEY_ALIASES.fetch(filter['attribute_key'], filter['attribute_key'])
      changed_attribute = @changed_attributes[backend_key].presence

      # Skip silently when the watched attribute did not change in this update.
      # Avoids NoMethodError on changed_attribute[0] which was being swallowed
      # by the rescue in #perform, masking real bugs.
      next unless changed_attribute.is_a?(Array) && changed_attribute.length >= 2

      if attribute_changed_match?(filter, changed_attribute)
        @attribute_changed_records = attribute_changed_filter_query(filter, records, current_attribute_changed_record)
      end
      current_attribute_changed_record = @attribute_changed_records
    end
  end

  def attribute_changed_match?(filter, changed_attribute)
    if filter['attribute_key'] == 'labels'
      labels_transition_match?(filter, changed_attribute)
    else
      scalar_transition_match?(filter, changed_attribute)
    end
  end

  # Mirrors the wildcard semantics of labels_transition_match?: an empty
  # `from` or `to` list means "any value on that side". Without this the
  # frontend can save `from: [], to: ['resolved']` (intent: any status ->
  # resolved) and Ruby's `Array.in?([])` is always false, so the rule never
  # fires.
  def scalar_transition_match?(filter, changed_attribute)
    # EVO-1642: coerce both sides to String before comparing. Condition values
    # are stored as strings (e.g. 'true'), but changed_attribute can carry the
    # native type (e.g. boolean false for `blocked`), so `false.in?(['false'])`
    # was silently never matching. Mirrors the Ruby contact evaluator.
    from_values = Array(filter['values']['from']).map(&:to_s)
    to_values = Array(filter['values']['to']).map(&:to_s)

    from_match = from_values.empty? || changed_attribute[0].to_s.in?(from_values)
    to_match = to_values.empty? || changed_attribute[1].to_s.in?(to_values)

    from_match && to_match
  end

  # Labels are array-valued (label_list via acts-as-taggable). Match by diff:
  # `to` is satisfied when at least one of the requested labels was added in
  # this update; `from` is satisfied when at least one was removed. An empty
  # `to`/`from` acts as a wildcard for that direction.
  def labels_transition_match?(filter, changed_attribute)
    previous_labels = Array(changed_attribute[0])
    current_labels = Array(changed_attribute[1])
    from_titles = label_titles_from_ids(filter['values']['from'])
    to_titles = label_titles_from_ids(filter['values']['to'])

    added = current_labels - previous_labels
    removed = previous_labels - current_labels

    return false if to_titles.any? && !added.intersect?(to_titles)
    return false if from_titles.any? && !removed.intersect?(from_titles)

    true
  end

  def label_titles_from_ids(ids)
    return [] if ids.blank?

    Label.where(id: Array(ids)).pluck(:title)
  end

  # We intersect with the record if query_operator-AND is present and union if query_operator-OR is present
  def attribute_changed_filter_query(filter, records, current_attribute_changed_record)
    if filter['query_operator'] == 'AND'
      @attribute_changed_records + (current_attribute_changed_record & records)
    else
      @attribute_changed_records + (current_attribute_changed_record | records)
    end
  end

  def message_query_string(current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    attribute_key = 'processed_message_content' if attribute_key == 'content'

    filter_operator_value = filter_operation(query_hash, current_index)

    case current_filter['attribute_type']
    when 'standard'
      if current_filter['data_type'] == 'text'
        " LOWER(messages.#{attribute_key}) #{filter_operator_value} #{query_operator} "
      else
        " messages.#{attribute_key} #{filter_operator_value} #{query_operator} "
      end
    end
  end

  # This will be used in future for contact automation rule
  def contact_query_string(current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    # Para labels, converte IDs (UUIDs) para títulos. O frontend salva o id
    # da Label no `values`, mas o tag (`tags.name`) é comparado pelo título.
    # Se o item não bater como UUID (ex.: regras antigas que já gravaram o
    # título) ou se a Label não existir mais, mantemos o valor original como
    # fallback para não converter silenciosamente um valor válido em vazio.
    if attribute_key == 'labels'
      raw_values = Array(query_hash['values']).map(&:to_s)
      titles_by_id = Label.where(id: raw_values).pluck(:id, :title).to_h.transform_keys(&:to_s)
      resolved = raw_values.map { |v| titles_by_id[v] || v }
      query_hash = query_hash.merge('values' => resolved)
    end

    filter_operator_value = filter_operation(query_hash, current_index)
    filter_operator = query_hash['filter_operator']

    case current_filter['attribute_type']
    when 'additional_attributes'
      column = "contacts.additional_attributes ->> '#{attribute_key}'"
      " #{contact_predicate(column, filter_operator_value, filter_operator)} #{query_operator} "
    when 'standard'
      if attribute_key == 'labels'
        labels_query_fragment(query_hash, current_index, query_operator)
      else
        " #{contact_predicate("contacts.#{attribute_key}", filter_operator_value, filter_operator)} #{query_operator} "
      end
    end
  end

  # EVO-1642: the retired Ruby contact evaluator treated a nil/absent value as
  # SATISFYING the negative operators (`!values.include?(nil)` for not_equal_to,
  # `none?` over `nil&.include?` for does_not_contain). SQL's `NULL NOT IN (...)`
  # / `NULL NOT ILIKE ...` evaluate to NULL (row excluded), which silently
  # stopped such rules from firing for contacts whose column is null. Make the
  # negative operators NULL-inclusive on the contact path to preserve behaviour.
  def contact_predicate(column, filter_operator_value, filter_operator)
    predicate = "#{column} #{filter_operator_value}"
    # Only on the contact-only path (no conversation) do we restore the retired
    # Ruby evaluator's NULL-inclusive negatives. The conversation path keeps its
    # existing SQL semantics so live conversation-rule behaviour is unchanged.
    return predicate unless @conversation.nil? && %w[not_equal_to does_not_contain].include?(filter_operator)

    "(#{predicate} OR #{column} IS NULL)"
  end

  def conversation_query_string(table_name, current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    # Para labels, converte IDs (UUIDs) para títulos. O frontend salva o id
    # da Label no `values`, mas o tag (`tags.name`) é comparado pelo título.
    # Se o item não bater como UUID (ex.: regras antigas que já gravaram o
    # título) ou se a Label não existir mais, mantemos o valor original como
    # fallback para não converter silenciosamente um valor válido em vazio.
    if attribute_key == 'labels'
      raw_values = Array(query_hash['values']).map(&:to_s)
      titles_by_id = Label.where(id: raw_values).pluck(:id, :title).to_h.transform_keys(&:to_s)
      resolved = raw_values.map { |v| titles_by_id[v] || v }
      query_hash = query_hash.merge('values' => resolved)
    end

    filter_operator_value = filter_operation(query_hash, current_index)

    case current_filter['attribute_type']
    when 'additional_attributes'
      " #{table_name}.additional_attributes ->> '#{attribute_key}' #{filter_operator_value} #{query_operator} "
    when 'standard'
      if attribute_key == 'labels'
        labels_query_fragment(query_hash, current_index, query_operator)
      else
        " #{table_name}.#{attribute_key} #{filter_operator_value} #{query_operator} "
      end
    end
  end

  private

  # Builds a self-contained EXISTS / NOT EXISTS fragment for a `labels`
  # condition. Each label condition is independent of any others (no shared
  # JOIN row), and it natively handles the "this label is absent" case via
  # NOT EXISTS — which is what users mean by `labels != X`, including the
  # case where the conversation has zero labels at all (a NULL row in a LEFT
  # JOIN would not satisfy NOT IN).
  #
  # The subquery looks up taggings on both the Conversation and its Contact,
  # mirroring the rest of the CRM where a "conversation label" is the union
  # of conversation- and contact-level tags.
  def labels_query_fragment(query_hash, current_index, query_operator)
    filter_operator = query_hash[:filter_operator] || query_hash['filter_operator']
    # EVO-1642: is_present / is_not_present ask "does the record have ANY label"
    # — there are no specific titles to match, so the `name IN (...)` clause is
    # dropped. Without this they degraded to `IN (<empty>)` and never matched.
    presence = %w[is_present is_not_present].include?(filter_operator)
    negate = %w[not_equal_to is_not_present].include?(filter_operator)

    existence = negate ? 'NOT EXISTS' : 'EXISTS'

    # EVO-1642: with a conversation the "label" is the union of conversation-
    # and contact-level tags; for a contact-only rule (no conversation in the
    # base relation) only the contact's own tags exist.
    taggable_match =
      if @conversation.present?
        "(lbl_tg.taggable_type = 'Conversation' AND lbl_tg.taggable_id = conversations.id) " \
          "OR (lbl_tg.taggable_type = 'Contact' AND lbl_tg.taggable_id = contacts.id)"
      else
        "lbl_tg.taggable_type = 'Contact' AND lbl_tg.taggable_id = contacts.id"
      end

    name_clause = presence ? '' : "AND lbl_t.name IN (:value_#{current_index})"

    subquery = <<~SQL.squish
      SELECT 1
        FROM taggings AS lbl_tg
        JOIN tags    AS lbl_t ON lbl_t.id = lbl_tg.tag_id
       WHERE lbl_tg.context = 'labels'
         AND (#{taggable_match})
         #{name_clause}
    SQL

    @filter_values["value_#{current_index}"] = Array(query_hash['values']) unless presence

    " #{existence} (#{subquery}) #{query_operator} "
  end

  def extract_filters(query_hash)
    {
      conversation: @conversation_filters[query_hash['attribute_key']],
      contact: @contact_filters[query_hash['attribute_key']],
      message: @message_filters[query_hash['attribute_key']]
    }
  end

  def build_query_string(filters, query_hash, current_index)
    # EVO-1642: some keys (e.g. country_code, labels) live in BOTH the
    # conversations and contacts filter sections. With no conversation in the
    # base relation, resolve them against contacts — otherwise the query would
    # reference the absent `conversations` table and error out.
    return contact_query_string(filters[:contact], query_hash.with_indifferent_access, current_index) if @conversation.nil? && filters[:contact]

    if filters[:conversation]
      conversation_query_string('conversations', filters[:conversation], query_hash.with_indifferent_access, current_index)
    elsif filters[:contact]
      contact_query_string(filters[:contact], query_hash.with_indifferent_access, current_index)
    elsif filters[:message]
      message_query_string(filters[:message], query_hash.with_indifferent_access, current_index)
    elsif pipeline_filter?(query_hash['attribute_key'])
      pipeline_query_string(query_hash.with_indifferent_access, current_index)
    elsif custom_attribute(query_hash['attribute_key'], query_hash['custom_attribute_type'])
      custom_attribute_query(query_hash.with_indifferent_access, query_hash['custom_attribute_type'], current_index)
    else
      ''
    end
  end

  def pipeline_filter?(attribute_key)
    %w[pipeline_id pipeline_stage_id].include?(attribute_key)
  end

  def pipeline_query_string(query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']
    filter_operator_value = filter_operation(query_hash, current_index)

    " pipeline_items.#{attribute_key} #{filter_operator_value} #{query_operator} "
  end

  def base_relation
    # EVO-1642: contact-only rules (no conversation) match directly against the
    # contact row. Only contacts.* columns and the labels EXISTS subquery are
    # referenced for these rules (see rule_has_only_contact_conditions?), so no
    # conversation/message/pipeline JOIN is needed.
    # No conversation in scope -> contact-only rule. `@contact&.id` (rather than
    # requiring @contact.present?) keeps a nil contact from falling through to
    # `Conversation.where(id: @conversation.id)` and raising on nil — it yields
    # an empty relation (no match) instead.
    return Contact.where(id: @contact&.id) if @conversation.nil?

    records = Conversation.where(id: @conversation.id).joins(
      'LEFT OUTER JOIN contacts on conversations.contact_id = contacts.id'
    ).joins(
      'LEFT OUTER JOIN messages on messages.conversation_id = conversations.id'
    ).joins(
      'LEFT OUTER JOIN pipeline_items on pipeline_items.conversation_id = conversations.id'
    ).joins(
      'LEFT OUTER JOIN pipeline_stages on pipeline_stages.id = pipeline_items.pipeline_stage_id'
    ).joins(
      'LEFT OUTER JOIN pipelines on pipelines.id = pipeline_items.pipeline_id'
    )

    # Conditions de `labels` agora viram subqueries EXISTS no próprio
    # query_string (ver labels_query_fragment). O JOIN antigo de
    # taggings+tags se mostrou frágil em dois cenários:
    #   1. múltiplas condições de labels disputavam o mesmo row do JOIN,
    #      então `labels=A AND labels!=B` nunca casava ao mesmo tempo;
    #   2. operadores `not_equal_to` com LEFT JOIN ignoravam rows com
    #      tags.name IS NULL (NULL não satisfaz NOT IN em SQL padrão).
    # Não precisamos mais do JOIN aqui.

    records = records.where(messages: { id: @options[:message].id }) if @options[:message].present?
    records
  end
end
