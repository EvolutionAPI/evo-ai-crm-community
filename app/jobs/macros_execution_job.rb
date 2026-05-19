class MacrosExecutionJob < ApplicationJob
  queue_as :medium

  def perform(macro, conversation_ids:, user:)
    ids = conversation_ids.to_a
    # Support both UUID and display_id (integer) lookups
    conversations = if ids.any? { |id| id.to_s.include?('-') }
                      Conversation.where(id: ids)
                    else
                      Conversation.where(display_id: ids)
                    end

    return if conversations.blank?

    conversations.map do |conversation|
      ::Macros::ExecutionService.new(macro, conversation, user).perform
    end
  end
end
