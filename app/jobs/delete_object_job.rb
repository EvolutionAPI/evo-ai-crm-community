class DeleteObjectJob < ApplicationJob
  queue_as :low
  INBOX_CONVERSATION_BATCH_SIZE = 100

  def perform(object, user = nil, ip = nil)
    cleanup_before_destroy!(object)

    object.destroy!
    process_post_deletion_tasks(object, user, ip)
  end

  def process_post_deletion_tasks(object, user, ip); end

  private

  def cleanup_before_destroy!(object)
    if object.is_a?(Inbox)
      cleanup_inbox_conversations!(object)
      return
    end

    cleanup_conversation_dependencies!(object) if object.is_a?(Conversation)
  end

  def cleanup_inbox_conversations!(inbox)
    conversations = inbox.conversations
    total_conversations = conversations.count
    failed_conversations = 0

    Rails.logger.info(
      "[DeleteObjectJob] Inbox cleanup started - inbox_id=#{inbox.id}, conversations_count=#{total_conversations}"
    )

    conversations.find_in_batches(batch_size: INBOX_CONVERSATION_BATCH_SIZE) do |batch|
      batch.each do |conversation|
        begin
          cleanup_conversation_dependencies!(conversation)
          conversation.destroy!
        rescue StandardError => e
          failed_conversations += 1
          Rails.logger.error(
            "[DeleteObjectJob] Failed deleting conversation #{conversation.id} for inbox #{inbox.id}: #{e.class} - #{e.message}"
          )
        end
      end
    end

    Rails.logger.info(
      "[DeleteObjectJob] Inbox cleanup finished - inbox_id=#{inbox.id}, conversations_count=#{total_conversations}, failed=#{failed_conversations}"
    )
  end

  def cleanup_conversation_dependencies!(conversation)
    conversation.facebook_comment_moderations.destroy_all
    conversation.pipeline_items.destroy_all
    # Same FK as EVO-2186: macro_executions -> conversations has no ON DELETE
    # CASCADE and Conversation declares no has_many :macro_executions, so it must
    # be cleared here or conversation.destroy! raises PG::ForeignKeyViolation.
    # Reached by DELETE /api/v1/conversations/:id and by the inbox cleanup above.
    MacroExecution.where(conversation_id: conversation.id).destroy_all
    conversation.mentions.destroy_all
    conversation.conversation_participants.destroy_all
    conversation.notifications.destroy_all
    conversation.reporting_events.destroy_all
    conversation.csat_survey_response&.destroy!
    conversation.messages.destroy_all
  end
end

DeleteObjectJob.prepend_mod_with('DeleteObjectJob')
