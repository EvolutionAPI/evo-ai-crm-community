class MacrosExecutionJob < ApplicationJob
  # Only the id -> Conversation mapping. The inbox authorization the
  # ConversationsController layers on top of it has no equivalent here.
  include ConversationResolver

  Result = Struct.new(:requested_ids, :executions, :unresolved_ids, keyword_init: true)

  DIGITS_ONLY = /\A\d+\z/
  UNRESOLVED_LOG_LIMIT = 20

  queue_as :medium

  def perform(macro, conversation_ids:, user:)
    # Blank entries are payload junk, not conversations that failed to resolve.
    requested_ids = Array(conversation_ids).map(&:to_s).reject(&:blank?)
    conversations, unresolved_ids = resolve_all(requested_ids)

    if unresolved_ids.any?
      Rails.logger.warn(
        "[macros] macro=#{macro.id} did not resolve #{unresolved_ids.size} of " \
        "#{requested_ids.size} conversation_ids: #{unresolved_log(unresolved_ids)}"
      )
    end

    Result.new(
      requested_ids: requested_ids,
      executions: conversations.map { |conversation| ::Macros::ExecutionService.new(macro, conversation, user).perform },
      unresolved_ids: unresolved_ids
    )
  end

  private

  def resolve_all(requested_ids)
    index = conversation_index(requested_ids)
    resolved = {}
    unresolved = []

    requested_ids.each do |id|
      conversation = index[id]

      if conversation.nil?
        unresolved << id
      else
        # One conversation reachable by both uuid and display_id still runs once.
        resolved[conversation.id] ||= conversation
      end
    end

    [resolved.values, unresolved.uniq]
  end

  # Client-supplied strings: cap the list and each entry so one request cannot flood the log.
  def unresolved_log(unresolved_ids)
    sample = unresolved_ids.first(UNRESOLVED_LOG_LIMIT).map { |id| id.truncate(64) }
    sample.join(', ') + (unresolved_ids.size > UNRESOLVED_LOG_LIMIT ? ', …' : '')
  end

  def conversation_index(requested_ids)
    candidates = requested_ids.uniq
    uuids, rest = candidates.partition { |id| uuid_format?(id) }
    # Anything neither uuid nor digits is left out: `where(display_id: 'abc')` casts to 0.
    display_ids = rest.select { |id| id.match?(DIGITS_ONLY) }.map(&:to_i)

    by_display_id = display_ids.any? ? Conversation.where(display_id: display_ids).index_by(&:display_id) : {}
    by_uuid = uuids.any? ? uuid_lookup(uuids) : {}

    candidates.each_with_object({}) do |id, index|
      # Keyed by the id as sent, so '007' finds display_id 7 and an upper-case uuid matches.
      conversation = uuid_format?(id) ? by_uuid[id.downcase] : by_display_id[id.to_i]
      index[id] = conversation if conversation
    end
  end

  # Set-form mirror of ConversationResolver#find_conversation_by_uuid: the primary key is
  # merged last so it wins over the `uuid` column. Change that precedence and change this.
  def uuid_lookup(uuids)
    Conversation.where(uuid: uuids).index_by { |c| c.uuid.to_s.downcase }
                .merge(Conversation.where(id: uuids).index_by { |c| c.id.to_s.downcase })
  end
end
