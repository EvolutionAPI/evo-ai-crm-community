# frozen_string_literal: true

# Servico para cache das contagens de conversas para melhorar performance
class Conversations::CachedCountService
  include Wisper::Publisher

  CACHE_EXPIRY = 5.minutes

  def initialize(user, _account = nil, filters = {})
    @user = user
    @filters = filters
  end

  def perform
    cache_key = build_cache_key

    Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRY) do
      calculate_counts_from_database
    end
  end

  def invalidate_cache
    pattern = "conversations:counts:#{@user.id}:*"

    # Use Redis SCAN for pattern matching
    Redis.current.scan_each(match: pattern) do |key|
      Rails.cache.delete(key)
    end
  end

  private

  def build_cache_key
    filters_hash = @filters.sort.to_h.hash
    "conversations:counts:#{@user.id}:#{filters_hash}"
  end

  def calculate_counts_from_database
    base_query = Conversation.all

    # Apply filters efficiently
    base_query = apply_filters(base_query)

    # Single query with grouping for all counts
    grouped_counts = base_query
                      .group(:assignee_id, :status)
                      .count

    # Process grouped results efficiently
    process_grouped_counts(grouped_counts)
  end

  def apply_filters(query)
    # Apply most selective filters first
    query = apply_inbox_filter(query) if @filters[:inbox_id]
    query = apply_permission_filter(query)
    query = apply_team_filter(query) if @filters[:team_id]
    query = apply_labels_filter(query) if @filters[:labels]

    query
  end

  def apply_inbox_filter(query)
    inbox_ids = if @filters[:inbox_id]
                  @user.assigned_inboxes.where(id: @filters[:inbox_id]).pluck(:id)
                else
                  @user.assigned_inboxes.pluck(:id)
                end

    query.where(inbox_id: inbox_ids)
  end

  def apply_permission_filter(query)
    is_admin = @user.administrator?
    return query if is_admin

    # Scope by the role-aware `assigned_inboxes` (same source as
    # ConversationFinder#apply_permission_filter and apply_inbox_filter above):
    # admins and users granted `conversations.read_all` see every inbox; a user with
    # `inbox_member` rows sees only those; and a user with NO membership and no
    # read_all sees NONE — there is deliberately no zero-membership "see all"
    # fallback (User#assigned_inboxes). Sharing that source is what keeps the cached
    # count consistent with the conversation list (no 0/74 split).
    query.where(inbox: @user.assigned_inboxes)
  end

  def apply_team_filter(query)
    team = Team.find(@filters[:team_id])
    query.where(team: team)
  end

  def apply_labels_filter(query)
    query.tagged_with(@filters[:labels], any: true)
  end

  def process_grouped_counts(grouped_counts)
    # Initialize counters
    counts = {
      open: { mine: 0, assigned: 0, unassigned: 0, all: 0 },
      resolved: { mine: 0, assigned: 0, unassigned: 0, all: 0 },
      pending: { mine: 0, assigned: 0, unassigned: 0, all: 0 },
      snoozed: { mine: 0, assigned: 0, unassigned: 0, all: 0 }
    }

    # Map enum values to symbols
    status_mapping = {
      0 => :open,
      1 => :resolved,
      2 => :pending,
      3 => :snoozed
    }

    # Process grouped results
    grouped_counts.each do |(assignee_id, status), count|
      status_sym = status_mapping[status] || :open

      counts[status_sym][:all] += count

      if assignee_id.nil?
        counts[status_sym][:unassigned] += count
      else
        counts[status_sym][:assigned] += count
        counts[status_sym][:mine] += count if assignee_id == @user.id
      end
    end

    # Legacy format compatibility
    {
      mine_count: counts[:open][:mine],
      assigned_count: counts[:open][:assigned],
      unassigned_count: counts[:open][:unassigned],
      all_count: counts[:open][:all],
      # Include detailed breakdown for future use
      detailed_counts: counts
    }
  end
end
