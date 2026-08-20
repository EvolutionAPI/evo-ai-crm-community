class MacrosExecutionJob < ApplicationJob
  # Same id -> Conversation mapping the ConversationsController uses, so the two
  # cannot disagree about what "this conversation" means.
  include ConversationResolver

  # Struct instead of a bare array: the caller has to tell "3 executions" from
  # "3 executions and 2 ids nobody could resolve", and an array cannot carry that.
  Result = Struct.new(:requested_ids, :executions, :unresolved_ids, keyword_init: true)

  queue_as :medium

  def perform(macro, conversation_ids:, user:)
    requested_ids = Array(conversation_ids).map(&:to_s)
    conversations, unresolved_ids = resolve_all(requested_ids)

    if unresolved_ids.any?
      Rails.logger.warn(
        "[macros] macro=#{macro.id} did not resolve #{unresolved_ids.size} of " \
        "#{requested_ids.size} conversation_ids: #{unresolved_ids.join(', ')}"
      )
    end

    Result.new(
      requested_ids: requested_ids,
      executions: conversations.map { |conversation| ::Macros::ExecutionService.new(macro, conversation, user).perform },
      unresolved_ids: unresolved_ids
    )
  end

  private

  # Resolves id by id. The previous heuristic decided uuid-vs-display_id for the WHOLE
  # list from a single hyphen, so a mixed list silently dropped every display_id in it.
  def resolve_all(requested_ids)
    resolved = {}
    unresolved = []

    requested_ids.each do |id|
      # A blank id is reported as unresolved rather than skipped: dropping it here is
      # the same silent disappearance this job is being fixed for.
      conversation = id.blank? ? nil : resolve_conversation(id)

      if conversation.nil?
        unresolved << id
      else
        # Same conversation reachable by uuid AND display_id in one call must still
        # run the macro once.
        resolved[conversation.id] ||= conversation
      end
    end

    [resolved.values, unresolved.uniq]
  end
end
