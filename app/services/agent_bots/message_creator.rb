class AgentBots::MessageCreator
  def initialize(agent_bot)
    @agent_bot = agent_bot
  end

  def create_bot_reply(content, conversation, force: false, content_type: 'text', content_attributes: nil)
    return if content.blank?

    # If force is true, skip eligibility check (e.g., for final response after transfer)
    unless force
      unless conversation_eligible_for_bot_reply?(conversation)
        Rails.logger.warn "[AgentBot HTTP] ⚠️  Bot response blocked - conversation #{conversation.id} not eligible for bot reply"
        Rails.logger.warn "[AgentBot HTTP] This can happen if status/labels/ignored_labels don't match bot configuration"
        return
      end
    else
      Rails.logger.info "[AgentBot HTTP] Force creating bot reply (skipping eligibility check) in conversation #{conversation.id}"
    end

    Rails.logger.info "[AgentBot HTTP] Creating bot reply in conversation #{conversation.id}"
    create_message_with_fallback(content, conversation, content_type: content_type, content_attributes: content_attributes)
  end

  private

  def conversation_eligible_for_bot_reply?(conversation)
    # Find the AgentBotInbox configuration for this conversation's inbox
    agent_bot_inbox = AgentBotInbox.find_by(agent_bot: @agent_bot, inbox: conversation.inbox)

    unless agent_bot_inbox
      Rails.logger.warn "[AgentBot HTTP] No AgentBotInbox found for agent_bot #{@agent_bot.id} and inbox #{conversation.inbox.id}"
      # Fallback to legacy behavior: only pending conversations
      is_pending = conversation.status == 'pending'
      Rails.logger.debug { "[AgentBot HTTP] Conversation status check (legacy): #{conversation.status} -> eligible: #{is_pending}" }
      return is_pending
    end

    # Use the same logic as AgentBotListener: check if conversation matches configuration
    Rails.logger.info "[AgentBot HTTP] Checking conversation eligibility for bot reply:"
    Rails.logger.info "[AgentBot HTTP]   Conversation: #{conversation.id} (status: #{conversation.status})"
    Rails.logger.info "[AgentBot HTTP]   Allowed statuses: #{agent_bot_inbox.allowed_conversation_statuses.inspect}"
    Rails.logger.info "[AgentBot HTTP]   Allowed labels: #{agent_bot_inbox.allowed_label_ids.inspect}"
    Rails.logger.info "[AgentBot HTTP]   Ignored labels: #{agent_bot_inbox.ignored_label_ids.inspect}"

    eligible = agent_bot_inbox.should_process_conversation?(conversation)

    if eligible
      Rails.logger.info "[AgentBot HTTP] ✅ Conversation is eligible for bot reply"
    else
      Rails.logger.warn "[AgentBot HTTP] ❌ Conversation NOT eligible - failed status/labels/ignored_labels check"
    end

    eligible
  end

  def create_message_with_fallback(content, conversation, content_type:, content_attributes:)
    create_direct_message(content, conversation, content_type: content_type, content_attributes: content_attributes)
  rescue StandardError => e
    log_creation_error(e)
    create_message_with_builder(content, conversation, content_type: content_type, content_attributes: content_attributes)
  end

  def create_direct_message(content, conversation, content_type:, content_attributes:)
    message_attributes = {
      inbox: conversation.inbox,
      conversation: conversation,
      content: content,
      message_type: 'outgoing',
      sender: @agent_bot,
      content_type: content_type
    }

    merged_content_attributes = {}
    merged_content_attributes.merge!(content_attributes) if content_attributes.present?

    # Check if send_as_reply is enabled in bot_config
    send_as_reply = @agent_bot.bot_config&.dig('send_as_reply') == true

    # For post conversations, always reply to the last incoming message
    # OR if send_as_reply is enabled in bot_config
    if conversation.post_conversation? || send_as_reply
      reply_attributes = build_reply_attributes(conversation)
      merged_content_attributes.merge!(reply_attributes) if reply_attributes.present?
    end

    message_attributes[:content_attributes] = merged_content_attributes if merged_content_attributes.present?

    message = Message.create!(message_attributes)

    Rails.logger.info "[AgentBot HTTP] Successfully created message #{message.id}"
    Rails.logger.info "[AgentBot HTTP] Reply attributes: #{message.content_attributes.slice(:in_reply_to, :in_reply_to_external_id).inspect}" if conversation.post_conversation? || send_as_reply
    Rails.logger.info '[AgentBot HTTP] Triggering message events'
    message
  end

  def log_creation_error(error)
    Rails.logger.error "[AgentBot HTTP] Failed to create reply message: #{error.message}"
    Rails.logger.error "[AgentBot HTTP] Backtrace: #{error.backtrace.first(5).join("\n")}"
    Rails.logger.info '[AgentBot HTTP] Trying with MessageBuilder as fallback'
  end

  def create_message_with_builder(content, conversation, content_type:, content_attributes:)
    message_params = { content: content, message_type: 'outgoing', content_type: content_type }

    merged_content_attributes = {}
    merged_content_attributes.merge!(content_attributes) if content_attributes.present?

    # Check if send_as_reply is enabled in bot_config
    send_as_reply = @agent_bot.bot_config&.dig('send_as_reply') == true

    # For post conversations, always reply to the last incoming message
    # OR if send_as_reply is enabled in bot_config
    if conversation.post_conversation? || send_as_reply
      reply_attributes = build_reply_attributes(conversation)
      merged_content_attributes.merge!(reply_attributes) if reply_attributes.present?
    end

    message_params[:content_attributes] = merged_content_attributes if merged_content_attributes.present?

    message = Messages::MessageBuilder.new(@agent_bot, conversation, message_params).perform
    Rails.logger.info "[AgentBot HTTP] MessageBuilder fallback successful: #{message.id}"
    Rails.logger.info "[AgentBot HTTP] Reply attributes: #{message.content_attributes.slice(:in_reply_to, :in_reply_to_external_id).inspect}" if conversation.post_conversation? || send_as_reply
    message
  rescue StandardError => e
    Rails.logger.error "[AgentBot HTTP] MessageBuilder fallback also failed: #{e.message}"
    nil
  end

  def build_reply_attributes(conversation)
    # Reload conversation to ensure we have the latest messages
    conversation.reload
    
    # Get all incoming messages for debugging
    all_incoming = Message.unscoped
                          .where(conversation_id: conversation.id)
                          .where(message_type: :incoming)
                          .order(created_at: :desc)
                          .limit(5)
                          .pluck(:id, :source_id, :content, :created_at)
    
    Rails.logger.info "[AgentBot HTTP] Last 5 incoming messages in conversation #{conversation.id}:"
    all_incoming.each_with_index do |(id, source_id, content, created_at), idx|
      Rails.logger.info "  [#{idx + 1}] ID: #{id}, source_id: #{source_id}, created_at: #{created_at}, content: #{content&.truncate(30)}"
    end
    
    # Get the last incoming message (the comment that triggered the bot)
    # Use unscoped to avoid any default scopes that might filter messages
    last_incoming_message = Message.unscoped
                                    .where(conversation_id: conversation.id)
                                    .where(message_type: :incoming)
                                    .order(created_at: :desc)
                                    .first

    unless last_incoming_message
      Rails.logger.warn "[AgentBot HTTP] No incoming message found for conversation #{conversation.id}"
      return {}
    end

    # Validate that the message exists and has required attributes
    unless last_incoming_message.id.present?
      Rails.logger.error "[AgentBot HTTP] Last incoming message has no ID: #{last_incoming_message.inspect}"
      return {}
    end

    # Double-check that the message still exists in the database
    unless Message.unscoped.exists?(id: last_incoming_message.id)
      Rails.logger.error "[AgentBot HTTP] Last incoming message #{last_incoming_message.id} no longer exists in database!"
      return {}
    end

    reply_attributes = {}

    # Set in_reply_to (internal message ID)
    reply_attributes[:in_reply_to] = last_incoming_message.id

    # Set in_reply_to_external_id (Facebook comment ID from source_id)
    if last_incoming_message.source_id.present?
      reply_attributes[:in_reply_to_external_id] = last_incoming_message.source_id
    end

    Rails.logger.info "[AgentBot HTTP] Building reply to message #{last_incoming_message.id} (source_id: #{last_incoming_message.source_id}, content: #{last_incoming_message.content&.truncate(50)})"

    reply_attributes
  end
end
