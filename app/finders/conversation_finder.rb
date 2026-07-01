# frozen_string_literal: true

# ConversationFinder otimizado para melhor performance
class ConversationFinder
  attr_reader :current_user, :params

  DEFAULT_STATUS = 'open'.freeze
  SORT_OPTIONS = {
    'last_activity_at_asc' => %w[sort_on_last_activity_at asc],
    'last_activity_at_desc' => %w[sort_on_last_activity_at desc],
    'created_at_asc' => %w[sort_on_created_at asc],
    'created_at_desc' => %w[sort_on_created_at desc],
    'priority_asc' => %w[sort_on_priority asc],
    'priority_desc' => %w[sort_on_priority desc],
    'waiting_since_asc' => %w[sort_on_waiting_since asc],
    'waiting_since_desc' => %w[sort_on_waiting_since desc],
    'latest' => %w[sort_on_last_activity_at desc]
  }.with_indifferent_access

  def initialize(current_user, params)
    @current_user = current_user
    # Avoid remote role lookup (evo-auth get_role) on conversations index hot path.
    @is_admin = current_user&.administrator? || false
    @has_conversations_read = false
    @params = params || {}
  end

  def perform
    return empty_result unless @current_user

    # Use single optimized query for counts with subquery
    counts = calculate_counts_optimized

    conversations = build_conversations_query

    {
      conversations: conversations,
      count: counts
    }
  rescue StandardError => e
    Rails.logger.error "ConversationFinder error: #{e.message}\n#{e.backtrace.join("\n")}"
    empty_result
  end

  private

  def empty_result
    {
      conversations: [],
      count: {
        mine_count: 0,
        assigned_count: 0,
        unassigned_count: 0,
        all_count: 0
      }
    }
  end

  def calculate_counts_optimized
    # Single query para calcular todas as contagens
    base_query = build_base_filter_query

    result = base_query.group(:assignee_id).count

    unassigned_count = result[nil] || 0
    mine_count = result[@current_user.id] || 0
    all_count = result.values.sum
    assigned_count = all_count - unassigned_count

    {
      mine_count: mine_count,
      assigned_count: assigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count
    }
  end

  def build_base_filter_query
    query = Conversation.all

    # Filter out conversations without contacts (data integrity)
    query = query.joins(:contact)

    # Apply inbox filtering first (most selective)
    query = apply_inbox_filter(query)

    # Apply permission filtering
    query = apply_permission_filter(query)

    # Apply status filter (indexed)
    query = apply_status_filter(query)

    # Apply other filters
    query = apply_team_filter(query)
    query = apply_labels_filter(query)
    query = apply_source_id_filter(query)

    query
  end

  def build_conversations_query
    query = build_base_filter_query

    # Apply assignee type filter
    query = apply_assignee_type_filter(query)

    # Apply chip filters (unread / groups / archived) — list-only, não afetam as contagens
    query = apply_unread_filter(query)
    query = apply_is_group_filter(query)
    query = apply_archived_filter(query)

    # Apply search filter if needed
    query = apply_query_filter(query) if @params[:q].present?

    # Complete eager loading to avoid N+1 queries
    # Keep preload minimal for index/search/filter. Heavy associations are loaded on show.
    # `pipeline_items` is included so the conversation list sidebar can render the
    # pipeline/stage chip — without this preload the serializer skips the
    # `pipelines` block (it only runs when the association is loaded), and the
    # chip only appears later if some other action triggers a refetch with the
    # association eager-loaded.
    query = query.preload(
      :inbox,
      :contact,
      :assignee,
      :team,
      :contact_inbox,
      pipeline_items: [:pipeline, :pipeline_stage]
    )

    # Apply sorting
    query = apply_sorting(query)

    # Apply pagination
    apply_pagination(query)
  end

  def apply_inbox_filter(query)
    return query unless @params[:inbox_id]

    inbox_ids = if @params[:inbox_id]
                  @current_user.assigned_inboxes.where(id: @params[:inbox_id]).pluck(:id)
                else
                  @current_user.assigned_inboxes.pluck(:id)
                end

    query.where(inbox_id: inbox_ids)
  end

  def apply_permission_filter(query)
    # Allow access if user is admin or has conversations.read permission
    return query if @is_admin || @has_conversations_read

    # Otherwise, filter by the inboxes the user may access. `assigned_inboxes`
    # (User#assigned_inboxes) is the role-aware source: admins / users granted
    # `conversations.read_all` see every inbox, a user with no `inbox_member`
    # assignment sees all (zero rupture on upgrade), and a user with assignments
    # sees only those. Using the raw `inboxes` relation here returned [] for any
    # user without an inbox_member — collapsing the list to "no conversations"
    # even for the account admin (the 0/74 bug).
    query.where(inbox: @current_user.assigned_inboxes)
  end

  def apply_status_filter(query)
    return query if @params[:status] == 'all'

    query.where(status: @params[:status] || DEFAULT_STATUS)
  end

  def apply_team_filter(query)
    return query unless @params[:team_id]

    team = Team.find(@params[:team_id])
    query.where(team: team)
  end

  def apply_labels_filter(query)
    return query unless @params[:labels]

    query.tagged_with(@params[:labels], any: true)
  end

  def apply_source_id_filter(query)
    return query unless @params[:source_id]

    query.joins(:contact_inbox)
         .where(contact_inboxes: { source_id: @params[:source_id] })
  end

  def apply_assignee_type_filter(query)
    case @params[:assignee_type]
    when 'me'
      query.assigned_to(@current_user)
    when 'unassigned'
      query.unassigned
    when 'assigned'
      query.assigned
    else
      query
    end
  end

  # Chip "Não lidas": conversas com mensagens incoming não lidas pelo agente.
  def apply_unread_filter(query)
    return query unless ActiveModel::Type::Boolean.new.cast(@params[:unread])

    query.unread
  end

  # Chip "Grupos": conversas cujo contato é um grupo (contact.type = 'group').
  # Naturalmente vazio em canais sem grupos (cloud/Telegram). O contato já está
  # joined em build_base_filter_query.
  def apply_is_group_filter(query)
    return query unless ActiveModel::Type::Boolean.new.cast(@params[:is_group])

    query.where(contacts: { type: 'group' })
  end

  # Aba "Arquivadas": archived vive em custom_attributes.archived (jsonb boolean).
  # archived=true  -> só arquivadas; archived=false -> exclui arquivadas.
  # Param ausente = sem filtro (lista padrão inalterada; o front esconde as
  # arquivadas client-side na visão normal). `->>'archived'` extrai o boolean JSON
  # como texto ('true'); IS DISTINCT FROM cobre null/false/ausente.
  def apply_archived_filter(query)
    return query if @params[:archived].blank?

    if ActiveModel::Type::Boolean.new.cast(@params[:archived])
      query.where("conversations.custom_attributes->>'archived' = 'true'")
    else
      query.where("conversations.custom_attributes->>'archived' IS DISTINCT FROM 'true'")
    end
  end

  def apply_query_filter(query)
    return query unless defined?(Message)

    allowed_message_types = [Message.message_types[:incoming], Message.message_types[:outgoing]]

    query.joins(:messages)
         .where('messages.content ILIKE ?', "%#{@params[:q]}%")
         .where(messages: { message_type: allowed_message_types })
         .distinct
  end

  def apply_sorting(query)
    sort_by, sort_order = SORT_OPTIONS[@params[:sort_by]] || SORT_OPTIONS['last_activity_at_desc']
    query.send(sort_by, sort_order)
  end

  def apply_pagination(query)
    if @params[:updated_within].present?
      query.where('conversations.updated_at > ?', Time.zone.now - @params[:updated_within].to_i.seconds)
    else
      current_page = positive_integer_param(@params[:page], 1)
      requested_per_page = @params[:per_page] || @params[:page_size] || @params[:pageSize]
      default_per_page = ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i
      per_page = positive_integer_param(requested_per_page, default_per_page)
      per_page = [per_page, 100].min
      query.page(current_page).per(per_page)
    end
  end

  def positive_integer_param(value, default_value)
    parsed_value = value.to_i
    parsed_value.positive? ? parsed_value : default_value
  end
end

ConversationFinder.prepend_mod_with('ConversationFinder')
