class AgentBotListener < BaseListener
  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    inbox = conversation.inbox
    return unless connected_agent_bot_exist?(inbox)
    return if BotRuntime::Config.enabled? # Bot Runtime does not process conversation events
    return unless should_process_conversation_event?(inbox, conversation)

    event_name = __method__.to_s
    payload = conversation.webhook_data.merge(event: event_name)
    process_webhook_bot_event(inbox.agent_bot, payload)
  end

  def conversation_opened(event)
    conversation = extract_conversation_and_account(event)[0]
    inbox = conversation.inbox
    return unless connected_agent_bot_exist?(inbox)
    return if BotRuntime::Config.enabled? # Bot Runtime does not process conversation events
    return unless should_process_conversation_event?(inbox, conversation)

    event_name = __method__.to_s
    payload = conversation.webhook_data.merge(event: event_name)
    process_webhook_bot_event(inbox.agent_bot, payload)
  end

  def message_created(event)
    message = extract_message_and_account(event)[0]
    inbox = message.inbox
    return unless connected_agent_bot_exist?(inbox)
    return unless message.webhook_sendable?

    conversation = message.conversation
    agent_bot_inbox = inbox.agent_bot_inbox

    # Skip messages created by moderation approval (to prevent duplicate processing)
    if message.content_attributes&.dig('moderation_approved') == true
      Rails.logger.info "[AgentBot Listener] Skipping - message created by moderation approval (moderation_id: #{message.content_attributes&.dig('moderation_id')})"
      return
    end

    # MODERATION MUST BE EXECUTED FIRST (before status/labels checks)
    # This ensures messages are moderated even if bot won't respond due to status/labels
    # Note: Only process moderation for incoming messages (not outgoing bot responses)
    Rails.logger.info "[AgentBot Listener] Moderation check - channel_type: #{inbox.channel_type}, agent_bot_inbox present?: #{agent_bot_inbox.present?}, moderation_enabled?: #{agent_bot_inbox&.moderation_enabled?}, message.incoming?: #{message.incoming?}"

    # Skip moderation for outgoing messages (messages sent by the bot/page)
    return unless message.incoming?

    # Reset inactivity actions when customer responds
    reset_inactivity_actions(conversation)

    # Skip moderation if message is from the page itself (not from external users)
    # Check if incoming message is from a contact where the sender's facebook_user_id matches the page_id (Facebook only)
    is_from_page = false
    if inbox.facebook? && message.sender.is_a?(Contact)
      sender_facebook_id = message.sender.additional_attributes&.dig('facebook_user_id')
      page_id = inbox.channel.is_a?(Channel::FacebookPage) ? inbox.channel.page_id : nil

      if sender_facebook_id.present? && page_id.present? && sender_facebook_id.to_s == page_id.to_s
        is_from_page = true
        Rails.logger.info "[AgentBot Listener] Skipping moderation - message is from page itself (sender: #{sender_facebook_id}, page: #{page_id})"
      end
    end

    if agent_bot_inbox&.moderation_enabled? && !is_from_page
      Rails.logger.info "[AgentBot Listener] Moderation enabled for #{inbox.channel_type} message, processing moderation FIRST"

      # Process moderation synchronously for explicit words and sentiment (to block immediately)
      # Then asynchronously for response generation if needed
      processor = Facebook::Moderation::ProcessorService.new(
        message: message,
        conversation: conversation,
        agent_bot_inbox: agent_bot_inbox
      )

      # This will check explicit words, sentiment, and create moderation records if needed
      # It returns early if explicit words or offensive sentiment is found
      processor.process

      # Check if moderation found explicit words or offensive sentiment
      # If so, don't process bot response (moderation will handle it)
      pending_deletion = FacebookCommentModeration.where(
        conversation: conversation,
        message: message,
        status: 'pending',
        moderation_type: %w[explicit_words offensive_sentiment]
      ).exists?

      if pending_deletion
        Rails.logger.info "[AgentBot Listener] Message flagged for deletion by moderation, skipping bot response"
        return
      end

      # Check if response approval is required
      # If so, don't process bot response immediately (it will be processed after approval)
      pending_response_approval = FacebookCommentModeration.where(
        conversation: conversation,
        message: message,
        status: 'pending',
        moderation_type: 'response_approval'
      ).exists?

      if pending_response_approval
        Rails.logger.info "[AgentBot Listener] Response approval required, skipping immediate bot response"
        return
      end
    elsif !agent_bot_inbox&.moderation_enabled?
      # When moderation is disabled, ignore any pending moderation records and process normally
      Rails.logger.info "[AgentBot Listener] Moderation disabled, processing message normally (ignoring any pending moderation records)"

      # Clean up any existing pending moderation records for this message when moderation is disabled
      # This ensures old moderation records don't block processing
      existing_pending = FacebookCommentModeration.where(
        conversation: conversation,
        message: message,
        status: 'pending'
      )

      if existing_pending.exists?
        Rails.logger.info "[AgentBot Listener] Found #{existing_pending.count} pending moderation record(s) for disabled moderation, cleaning up"
        existing_pending.destroy_all
      end
    end

    # For Facebook inboxes, check interaction type
    if inbox.facebook?
      is_post_conversation = conversation.post_conversation?

      if is_post_conversation
        Rails.logger.info "[AgentBot Listener] Facebook post conversation detected"

        # Check if bot should process comments (includes interaction type check)
        if agent_bot_inbox.present? && !agent_bot_inbox.should_process_facebook_comments?
          Rails.logger.info "[AgentBot Listener] Skipping - Facebook comments not enabled for this bot"
          return
        end

        # Check if comment replies are enabled (must be enabled to process comments)
        if agent_bot_inbox.present? && !agent_bot_inbox.facebook_comment_replies_enabled?
          Rails.logger.info "[AgentBot Listener] Skipping - Facebook comment replies disabled"
          return
        end

        # Check if this specific post is allowed
        if agent_bot_inbox.present? && conversation.post_id.present?
          unless agent_bot_inbox.post_allowed?(conversation.post_id)
            Rails.logger.info "[AgentBot Listener] Skipping - Post #{conversation.post_id} not in allowed list"
            return
          end
        end

        # Check status and labels (includes ignored labels check)
        if agent_bot_inbox.present? && (skip_reason = agent_bot_inbox.processing_block_reason(conversation))
          Rails.logger.info "[AgentBot Listener] Skipping message - conv #{conversation.id}: #{skip_reason}"
          return
        end
      else
        # Regular Facebook Messenger direct message
        Rails.logger.info "[AgentBot Listener] Facebook Messenger direct message detected"

        # Check if bot should process direct messages
        if agent_bot_inbox.present? && !agent_bot_inbox.should_process_facebook_messages?
          Rails.logger.info "[AgentBot Listener] Skipping - Facebook direct messages not enabled for this bot"
          return
        end

        # Check status and labels (includes ignored labels check)
        if agent_bot_inbox.present? && (skip_reason = agent_bot_inbox.processing_block_reason(conversation))
          Rails.logger.info "[AgentBot Listener] Skipping message - conv #{conversation.id}: #{skip_reason}"
          return
        end
      end
    else
      # For non-Facebook conversations, check status and labels (includes ignored labels check)
      if agent_bot_inbox.present? && (skip_reason = agent_bot_inbox.processing_block_reason(conversation))
        Rails.logger.info "[AgentBot Listener] Skipping message - conv #{conversation.id}: #{skip_reason}"
        return
      end
    end

    method_name = __method__.to_s
    agent_bot = get_agent_bot_for_message(inbox, message)
    return unless agent_bot

    process_message_event(method_name, agent_bot, message, event)
  end

  def message_updated(event)
    message = extract_message_and_account(event)[0]
    inbox = message.inbox
    return unless connected_agent_bot_exist?(inbox)
    return unless message.webhook_sendable?

    conversation = message.conversation
    agent_bot_inbox = inbox.agent_bot_inbox

    # MODERATION MUST BE EXECUTED FIRST (before status/labels checks)
    # This ensures messages are moderated even if bot won't respond due to status/labels
    # Note: Only process moderation for incoming messages (not outgoing bot responses)

    # Skip moderation for outgoing messages (messages sent by the bot/page)
    return unless message.incoming?

    # Reset inactivity actions when customer responds
    reset_inactivity_actions(conversation)

    # Skip moderation if message is from the page itself (not from external users)
    # Check if incoming message is from a contact where the sender's facebook_user_id matches the page_id (Facebook only)
    is_from_page = false
    if inbox.facebook? && message.sender.is_a?(Contact)
      sender_facebook_id = message.sender.additional_attributes&.dig('facebook_user_id')
      page_id = inbox.channel.is_a?(Channel::FacebookPage) ? inbox.channel.page_id : nil

      if sender_facebook_id.present? && page_id.present? && sender_facebook_id.to_s == page_id.to_s
        is_from_page = true
        Rails.logger.info "[AgentBot Listener] Skipping moderation (message_updated) - message is from page itself (sender: #{sender_facebook_id}, page: #{page_id})"
      end
    end

    if agent_bot_inbox&.moderation_enabled? && !is_from_page
      Rails.logger.info "[AgentBot Listener] Moderation enabled for #{inbox.channel_type} message (message_updated), processing moderation FIRST"

      # Process moderation synchronously for explicit words and sentiment (to block immediately)
      # Then asynchronously for response generation if needed
      processor = Facebook::Moderation::ProcessorService.new(
        message: message,
        conversation: conversation,
        agent_bot_inbox: agent_bot_inbox
      )

      # This will check explicit words, sentiment, and create moderation records if needed
      # It returns early if explicit words or offensive sentiment is found
      processor.process

      # Check if moderation found explicit words or offensive sentiment
      # If so, don't process bot response (moderation will handle it)
      pending_deletion = FacebookCommentModeration.where(
        conversation: conversation,
        message: message,
        status: 'pending',
        moderation_type: %w[explicit_words offensive_sentiment]
      ).exists?

      if pending_deletion
        Rails.logger.info "[AgentBot Listener] Message flagged for deletion by moderation, skipping bot response"
        return
      end

      # Check if response approval is required
      # If so, don't process bot response immediately (it will be processed after approval)
      pending_response_approval = FacebookCommentModeration.where(
        conversation: conversation,
        message: message,
        status: 'pending',
        moderation_type: 'response_approval'
      ).exists?

      if pending_response_approval
        Rails.logger.info "[AgentBot Listener] Response approval required, skipping immediate bot response"
        return
      end
    elsif !agent_bot_inbox&.moderation_enabled?
      # When moderation is disabled, ignore any pending moderation records and process normally
      Rails.logger.info "[AgentBot Listener] Moderation disabled (message_updated), processing message normally (ignoring any pending moderation records)"

      # Clean up any existing pending moderation records for this message when moderation is disabled
      # This ensures old moderation records don't block processing
      existing_pending = FacebookCommentModeration.where(
        conversation: conversation,
        message: message,
        status: 'pending'
      )

      if existing_pending.exists?
        Rails.logger.info "[AgentBot Listener] Found #{existing_pending.count} pending moderation record(s) for disabled moderation (message_updated), cleaning up"
        existing_pending.destroy_all
      end
    end

    # For Facebook inboxes, check interaction type
    if inbox.facebook?
      is_post_conversation = conversation.post_conversation?

      if is_post_conversation
        Rails.logger.info "[AgentBot Listener] Facebook post conversation detected"

        # Check if bot should process comments (includes interaction type check)
        if agent_bot_inbox.present? && !agent_bot_inbox.should_process_facebook_comments?
          Rails.logger.info "[AgentBot Listener] Skipping - Facebook comments not enabled for this bot"
          return
        end

        # Check if comment replies are enabled (must be enabled to process comments)
        if agent_bot_inbox.present? && !agent_bot_inbox.facebook_comment_replies_enabled?
          Rails.logger.info "[AgentBot Listener] Skipping - Facebook comment replies disabled"
          return
        end

        # Check if this specific post is allowed
        if agent_bot_inbox.present? && conversation.post_id.present?
          unless agent_bot_inbox.post_allowed?(conversation.post_id)
            Rails.logger.info "[AgentBot Listener] Skipping - Post #{conversation.post_id} not in allowed list"
            return
          end
        end

        # Check status and labels (includes ignored labels check)
        if agent_bot_inbox.present? && (skip_reason = agent_bot_inbox.processing_block_reason(conversation))
          Rails.logger.info "[AgentBot Listener] Skipping message - conv #{conversation.id}: #{skip_reason}"
          return
        end
      else
        # Regular Facebook Messenger direct message
        Rails.logger.info "[AgentBot Listener] Facebook Messenger direct message detected"

        # Check if bot should process direct messages
        if agent_bot_inbox.present? && !agent_bot_inbox.should_process_facebook_messages?
          Rails.logger.info "[AgentBot Listener] Skipping - Facebook direct messages not enabled for this bot"
          return
        end

        # Check status and labels (includes ignored labels check)
        if agent_bot_inbox.present? && (skip_reason = agent_bot_inbox.processing_block_reason(conversation))
          Rails.logger.info "[AgentBot Listener] Skipping message - conv #{conversation.id}: #{skip_reason}"
          return
        end
      end
    else
      # For non-Facebook conversations, check status and labels (includes ignored labels check)
      if agent_bot_inbox.present? && (skip_reason = agent_bot_inbox.processing_block_reason(conversation))
        Rails.logger.info "[AgentBot Listener] Skipping message - conv #{conversation.id}: #{skip_reason}"
        return
      end
    end

    method_name = __method__.to_s
    agent_bot = get_agent_bot_for_message(inbox, message)
    return unless agent_bot

    process_message_event(method_name, agent_bot, message, event)
  end

  def webwidget_triggered(event)
    contact_inbox = event.data[:contact_inbox]
    inbox = contact_inbox.inbox
    return unless connected_agent_bot_exist?(inbox)

    event_name = __method__.to_s
    payload = contact_inbox.webhook_data.merge(event: event_name)
    payload[:event_info] = event.data[:event_info]
    process_webhook_bot_event(inbox.agent_bot, payload)
  end

  def conversation_deleted(event)
    conversation = extract_conversation_and_account(event)[0]
    inbox = conversation.inbox
    return unless connected_agent_bot_exist?(inbox)

    # Bot Runtime manages its own sessions via Redis TTLs
    return if BotRuntime::Config.enabled?

    return unless inbox.agent_bot.evo_ai_provider?

    Rails.logger.info "[AgentBot Listener] conversation_deleted event received for conversation #{conversation.id}"

    # Schedule job to delete session from processor
    agent_bot = inbox.agent_bot
    AgentBots::DeleteSessionJob.perform_later(
      agent_bot.id,
      conversation.id,
      AgentBots::CredentialResolution.api_key_for(agent_bot),
      agent_bot.outgoing_url
    )

    Rails.logger.info "[AgentBot Listener] DeleteSessionJob scheduled for conversation #{conversation.id}"
  end

  private

  def connected_agent_bot_exist?(inbox)
    return false if inbox.agent_bot_inbox.blank?
    return false unless inbox.agent_bot_inbox.active?

    true
  end

  def should_process_conversation_event?(inbox, conversation)
    agent_bot_inbox = inbox.agent_bot_inbox
    return true if agent_bot_inbox.blank? # Mantém comportamento antigo se não houver configuração

    agent_bot_inbox.should_process_conversation?(conversation)
  end

  # Get the appropriate agent bot for a message
  # For Facebook post conversations, use the configured comment agent bot if available
  # Note: All filters (interaction type, comment replies enabled, post allowed, status/labels)
  # are already checked in message_created/message_updated before calling this method
  def get_agent_bot_for_message(inbox, message)
    agent_bot_inbox = inbox.agent_bot_inbox
    return inbox.agent_bot if agent_bot_inbox.blank?

    conversation = message.conversation

    # For Facebook post conversations, use comment-specific bot if configured
    if conversation.post_conversation? && inbox.facebook?
      Rails.logger.info "[AgentBot Listener] Facebook post conversation - selecting agent bot"
      Rails.logger.info "[AgentBot Listener] Comment replies enabled: #{agent_bot_inbox.facebook_comment_replies_enabled?}"
      Rails.logger.info "[AgentBot Listener] Comment-specific bot ID: #{agent_bot_inbox.facebook_comment_agent_bot_id}"

      # Use specific comment agent bot if configured, otherwise use main agent bot
      comment_agent_bot = agent_bot_inbox.facebook_comment_agent_bot || agent_bot_inbox.agent_bot
      Rails.logger.info "[AgentBot Listener] Using agent bot: #{comment_agent_bot&.name} (ID: #{comment_agent_bot&.id})"
      Rails.logger.info "[AgentBot Listener] Is comment-specific bot: #{agent_bot_inbox.facebook_comment_agent_bot.present?}"

      return comment_agent_bot
    end

    # For regular conversations (including Facebook Messenger direct messages), use main agent bot
    Rails.logger.info "[AgentBot Listener] Regular conversation, using main agent bot: #{agent_bot_inbox.agent_bot&.name}"
    agent_bot_inbox.agent_bot
  end

  def process_message_event(method_name, agent_bot, message, _event)
    # Only webhook bots are supported
    payload = message.webhook_data.merge(event: method_name)
    process_webhook_bot_event(agent_bot, payload)
  end


  def find_conversation_from_payload(payload)
    # Handle both ActiveRecord object and hash
    conversation_obj = payload[:conversation]

    Rails.logger.info "[AgentBot Listener] find_conversation_from_payload - conversation_obj class: #{conversation_obj.class}"
    Rails.logger.info "[AgentBot Listener] find_conversation_from_payload - conversation_obj: #{conversation_obj.inspect[0..200]}"

    if conversation_obj.is_a?(Conversation)
      # Already a Conversation object
      Rails.logger.info "[AgentBot Listener] Found Conversation object directly: #{conversation_obj.id}"
      return conversation_obj
    elsif conversation_obj.is_a?(Hash)
      # Hash with id key
      conversation_id = conversation_obj[:id] || conversation_obj['id']
      Rails.logger.info "[AgentBot Listener] Found conversation_id from hash: #{conversation_id}"
    else
      # Try conversation_id directly
      conversation_id = payload[:conversation_id]
      Rails.logger.info "[AgentBot Listener] Trying conversation_id from payload: #{conversation_id}"
    end

    return nil unless conversation_id

    # Get inbox_id from payload to ensure we find the correct conversation
    # when multiple conversations have the same display_id
    inbox_id = payload[:inbox_id]
    inbox_id ||= payload[:inbox]&.dig(:id) if payload[:inbox].is_a?(Hash)
    inbox_id ||= payload[:inbox]&.dig('id') if payload[:inbox].is_a?(Hash)
    inbox_id ||= payload[:inbox]&.id if payload[:inbox].respond_to?(:id)
    inbox_id ||= conversation_obj[:inbox_id] if conversation_obj.is_a?(Hash)
    inbox_id ||= conversation_obj['inbox_id'] if conversation_obj.is_a?(Hash)
    
    Rails.logger.info "[AgentBot Listener] Inbox ID from payload: #{inbox_id.inspect}"

    # The conversation hash in payload uses display_id (integer), not the UUID id
    # Try to find by display_id first if it's an integer, but also filter by inbox_id if available
    conversation = if conversation_id.is_a?(Integer) || conversation_id.to_s.match?(/^\d+$/)
      Rails.logger.info "[AgentBot Listener] Searching by display_id: #{conversation_id}"
      if inbox_id.present?
        Rails.logger.info "[AgentBot Listener] Also filtering by inbox_id: #{inbox_id}"
        Conversation.unscoped.where(display_id: conversation_id, inbox_id: inbox_id).first
      else
        Conversation.unscoped.find_by(display_id: conversation_id)
      end
    else
      # Try UUID id
      Rails.logger.info "[AgentBot Listener] Searching by UUID id: #{conversation_id}"
      if inbox_id.present?
        Rails.logger.info "[AgentBot Listener] Also filtering by inbox_id: #{inbox_id}"
        Conversation.unscoped.where(id: conversation_id, inbox_id: inbox_id).first
      else
        Conversation.unscoped.find_by(id: conversation_id)
      end
    end

    Rails.logger.info "[AgentBot Listener] Found conversation from DB: #{conversation&.id} (display_id: #{conversation&.display_id}, inbox_id: #{conversation&.inbox_id})"

    if conversation.nil?
      Rails.logger.warn "[AgentBot Listener] ⚠️  Conversation with id/display_id #{conversation_id} (#{conversation_id.class})#{inbox_id.present? ? " and inbox_id #{inbox_id}" : ""} not found in database"
    end

    conversation
  end

  def create_message_from_payload(payload, conversation)
    Message.new(
      id: payload[:id],
      content: payload[:content] || '',
      conversation: conversation,
      inbox: conversation.inbox,
      message_type: payload[:message_type] == 'incoming' ? :incoming : :outgoing,
      created_at: payload[:created_at] ? Time.zone.at(payload[:created_at]) : Time.current
    )
  end

  def process_webhook_bot_event(agent_bot, payload)
    return if agent_bot.outgoing_url.blank?

    # Bot Runtime handles debounce, AI calls and dispatch externally
    if BotRuntime::Config.enabled?
      delegate_to_bot_runtime(agent_bot, payload)
      return
    end

    # Fallback: direct call for webhook/n8n providers (no debounce)
    if agent_bot.webhook_provider?
      AgentBots::WebhookJob.perform_later(agent_bot.outgoing_url, payload)
    elsif agent_bot.n8n_provider?
      AgentBots::N8nRequestService.new(agent_bot, payload).perform
    else
      AgentBots::HttpRequestService.new(agent_bot, payload).perform
    end
  end

  def delegate_to_bot_runtime(agent_bot, payload)
    return unless incoming_message_event?(payload)

    conversation = find_conversation_from_payload(payload)
    return unless conversation

    message = create_message_from_payload(payload, conversation)
    # webhook_data only sets :attachments when the record has them, so this saves
    # the service a query on text-only messages.
    BotRuntime::DelegationService.new(
      agent_bot, message, conversation, has_attachments: payload[:attachments].present?
    ).delegate

    Rails.logger.info "[BotRuntime] Delegated message to Bot Runtime: " \
                      "conversation=#{conversation.display_id} bot=#{agent_bot.name}"
  rescue StandardError => e
    Rails.logger.error "[BotRuntime] Delegation failed: #{e.message}"
    Rails.logger.error "[BotRuntime] Backtrace: #{e.backtrace.first(5).join("\n")}"
  end

  def incoming_message_event?(payload)
    return false unless %w[message_created message_updated].include?(payload[:event])

    message_type = payload[:message_type]
    # Handle both string and integer message types
    message_type == 'incoming' || message_type == 0 || message_type == '0'
  end

  # Reset inactivity actions when customer responds
  def reset_inactivity_actions(conversation)
    Rails.logger.info "[AgentBot Listener] Resetting inactivity actions for conversation #{conversation.id}"
    InactivityActionExecution.reset_for_conversation(conversation.id)
  rescue StandardError => e
    Rails.logger.error "[AgentBot Listener] Error resetting inactivity actions: #{e.message}"
    # Don't propagate error - this shouldn't block message processing
  end
end
