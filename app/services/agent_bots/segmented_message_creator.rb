class AgentBots::SegmentedMessageCreator
  def initialize(agent_bot)
    @agent_bot = agent_bot
  end

  def should_reply_to_message?(conversation)
    # Check if send_as_reply is enabled in bot_config
    send_as_reply = @agent_bot.bot_config&.dig('send_as_reply') == true
    # For post conversations, always reply to the last incoming message
    # OR if send_as_reply is enabled in bot_config
    conversation.post_conversation? || send_as_reply
  end

  def create_messages(segments, conversation, force: false)
    return if segments.empty?

    # Verifica se a conversa é elegível para resposta do bot (a menos que force seja true)
    unless force
      unless conversation_eligible_for_bot_reply?(conversation)
        Rails.logger.debug { "[AgentBot Segmented] Conversation #{conversation.id} not eligible (status: #{conversation.status})" }
        # If not eligible and not forced, try with force anyway (for final responses after transfer)
        Rails.logger.info "[AgentBot Segmented] Attempting force create for conversation #{conversation.id}"
        return create_messages(segments, conversation, force: true)
      end
    else
      Rails.logger.info "[AgentBot Segmented] Force creating messages (skipping eligibility check) for conversation #{conversation.id}"
    end

    # Se não tem segmentação habilitada ou só tem um segmento, cria uma mensagem normal
    if !@agent_bot.text_segmentation_enabled || segments.length == 1
      content = segments.join('\n\n')
      content = build_message_with_signature(content)
      create_single_message(content, conversation)
      return
    end

    Rails.logger.info "[AgentBot Segmented] Processing #{segments.length} segments in chain"

    # Envia o primeiro segmento imediatamente
    Rails.logger.info '[AgentBot Segmented] Sending segment 0 immediately'
    process_segment_message(segments[0], conversation)

    # Se houver mais segmentos, agenda o próximo na cadeia
    return unless segments.length > 1

    Rails.logger.info "[AgentBot Segmented] Starting chain for remaining #{segments.length - 1} segments"
    schedule_next_segment(segments, 1, conversation)
  end

  def process_segment_message(segment, conversation)
    # Verifica se é mídia formatada
    if media_segment?(segment)
      create_media_message(segment, conversation)
    else
      content = build_message_with_signature(segment)
      create_single_message(content, conversation)
    end
  end

  def schedule_next_segment(segments, segment_index, conversation)
    return if segment_index >= segments.length

    # Calcula o delay baseado no segmento anterior
    previous_segment = segments[segment_index - 1]
    previous_segment_length = previous_segment.length

    # Calcula delay: caracteres × delay_per_character (em milissegundos)
    character_based_delay = (previous_segment_length * @agent_bot.delay_per_character).to_i

    # Delay mínimo de 500ms entre segmentos
    minimum_delay = 500
    segment_delay = [character_based_delay, minimum_delay].max

    Rails.logger.info "[AgentBot Segmented] Scheduling segment #{segment_index} with delay #{segment_delay}ms " \
                      "(chars: #{previous_segment_length}, multiplier: #{@agent_bot.delay_per_character})"

    # Agenda o próximo segmento na cadeia
    AgentBots::DelayedMessageJob.set(wait: segment_delay / 1000.0)
                                .perform_later(@agent_bot.id, segments, conversation.id, segment_index)
  end

  private

  def conversation_eligible_for_bot_reply?(conversation)
    # Find the AgentBotInbox configuration for this conversation's inbox
    agent_bot_inbox = AgentBotInbox.find_by(agent_bot: @agent_bot, inbox: conversation.inbox)

    unless agent_bot_inbox
      Rails.logger.warn "[AgentBot Segmented] No AgentBotInbox found for agent_bot #{@agent_bot.id} and inbox #{conversation.inbox.id}"
      # Fallback to legacy behavior: only pending conversations
      is_pending = conversation.status == 'pending'
      Rails.logger.debug { "[AgentBot Segmented] Conversation status check (legacy): #{conversation.status} -> eligible: #{is_pending}" }
      return is_pending
    end

    # Use the same logic as AgentBotListener: check if conversation matches configuration
    eligible = agent_bot_inbox.should_process_conversation?(conversation)
    Rails.logger.info "[AgentBot Segmented] Conversation status check: #{conversation.status}, Allowed statuses: #{agent_bot_inbox.allowed_conversation_statuses.inspect}, Eligible: #{eligible}"
    eligible
  end

  def media_segment?(segment)
    segment.match?(/^(audio|image|video|document)::(.*)@@(.+)$/)
  end

  def create_media_message(segment, conversation)
    return unless (matches = segment.match(/^(audio|image|video|document)::(.*)@@(.+)$/))

    media_type = matches[1]
    alt_text = matches[2]
    url = matches[3]

    case media_type
    when 'image'
      create_image_message(url, alt_text, conversation)
    when 'audio'
      create_audio_message(url, alt_text, conversation)
    when 'video'
      create_video_message(url, alt_text, conversation)
    when 'document'
      create_document_message(url, alt_text, conversation)
    end
  end

  def create_image_message(url, alt_text, conversation)
    create_media_message_with_attachment(
      conversation,
      content: (alt_text.presence || 'Imagem'),
      content_attributes: { image_url: url, content_type: 'image' },
      media: { url: url, file_type: 'image' }
    )
  end

  def create_audio_message(url, alt_text, conversation)
    create_media_message_with_attachment(
      conversation,
      content: (alt_text.presence || 'Áudio'),
      content_attributes: { audio_url: url, content_type: 'audio' },
      media: { url: url, file_type: 'audio' }
    )
  end

  def create_video_message(url, alt_text, conversation)
    create_media_message_with_attachment(
      conversation,
      content: (alt_text.presence || 'Vídeo'),
      content_attributes: { video_url: url, content_type: 'video' },
      media: { url: url, file_type: 'video' }
    )
  end

  def create_document_message(url, alt_text, conversation)
    create_media_message_with_attachment(
      conversation,
      content: (alt_text.presence || 'Documento'),
      # Attachment enum has no :document — documents map to :file.
      content_attributes: { document_url: url, content_type: 'document' },
      media: { url: url, file_type: 'file' }
    )
  end

  # Builds an outgoing media message AND downloads the remote URL into a real
  # Attachment before the message is saved.
  #
  # WHY the attachment matters: channel dispatch (e.g. WhatsApp Cloud's
  # send_attachment_message) decides text-vs-media by `message.attachments.present?`.
  # Storing the URL only in content_attributes renders fine in the CRM panel but
  # makes the channel send the *content* text (e.g. the literal "Vídeo") instead
  # of the media. The attachment MUST be built before save: Message#send_reply
  # runs on after_create_commit, so attaching post-save no longer re-sends.
  # This mirrors AgentBots::MessageCreator#create_direct_message.
  def create_media_message_with_attachment(conversation, content:, content_attributes:, media:)
    url = media[:url]

    # For post conversations or if send_as_reply is enabled, reply to the last incoming message
    if should_reply_to_message?(conversation)
      reply_attributes = build_reply_attributes(conversation)
      content_attributes.merge!(reply_attributes) if reply_attributes.present?
    end

    message = conversation.messages.new(
      inbox: conversation.inbox,
      message_type: :outgoing,
      content: content,
      sender: @agent_bot,
      content_attributes: content_attributes
    )

    AgentBots::RemoteMediaAttacher.build_attachments(message, [media])
    message.save!

    if message.attachments.present?
      Rails.logger.info "[AgentBot] Created #{media[:file_type]} message: #{message.id} with attachment from URL: #{url}"
    else
      Rails.logger.warn "[AgentBot] Created #{media[:file_type]} message: #{message.id} WITHOUT attachment (download failed) for URL: #{url} — channel will fall back to text"
    end
  end

  def create_single_message(content, conversation)
    message_attributes = {
      inbox: conversation.inbox,
      message_type: :outgoing,
      content: content,
      sender: @agent_bot
    }

    # For post conversations or if send_as_reply is enabled, reply to the last incoming message
    if should_reply_to_message?(conversation)
      reply_attributes = build_reply_attributes(conversation)
      message_attributes[:content_attributes] = reply_attributes if reply_attributes.present?
    end

    message = conversation.messages.create!(message_attributes)

    Rails.logger.info "[AgentBot] Created text message: #{message.id}"
    Rails.logger.info "[AgentBot] Reply attributes: #{message.content_attributes.slice(:in_reply_to, :in_reply_to_external_id).inspect}" if should_reply_to_message?(conversation)
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

    Rails.logger.info "[AgentBot Segmented] Last 5 incoming messages in conversation #{conversation.id}:"
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
      Rails.logger.warn "[AgentBot Segmented] No incoming message found for conversation #{conversation.id}"
      return {}
    end

    # Validate that the message exists and has required attributes
    unless last_incoming_message.id.present?
      Rails.logger.error "[AgentBot Segmented] Last incoming message has no ID: #{last_incoming_message.inspect}"
      return {}
    end

    # Double-check that the message still exists in the database
    unless Message.unscoped.exists?(id: last_incoming_message.id)
      Rails.logger.error "[AgentBot Segmented] Last incoming message #{last_incoming_message.id} no longer exists in database!"
      return {}
    end

    reply_attributes = {}

    # Set in_reply_to (internal message ID)
    reply_attributes[:in_reply_to] = last_incoming_message.id

    # Set in_reply_to_external_id (Facebook comment ID from source_id)
    if last_incoming_message.source_id.present?
      reply_attributes[:in_reply_to_external_id] = last_incoming_message.source_id
    end

    Rails.logger.info "[AgentBot Segmented] Building reply to message #{last_incoming_message.id} (source_id: #{last_incoming_message.source_id}, content: #{last_incoming_message.content&.truncate(50)})"

    reply_attributes
  end

  def build_message_with_signature(content)
    return content if @agent_bot.message_signature.blank?

    # Add signature at the top with two line breaks before the message
    "#{@agent_bot.message_signature}\n\n#{content}"
  end
end
