module Whatsapp::EvolutionGoHandlers::Helpers
  private

  def inbox
    @inbox
  end

  def account
    RuntimeConfig.account
  end

  def incoming?
    # This method is now defined in the service
    # Evolution Go: Check IsFromMe field from Info
    from_me = @evolution_go_info&.dig(:IsFromMe)

    if from_me.nil?
      Rails.logger.warn 'Evolution Go API: Unable to determine message direction from IsFromMe field, assuming incoming'
      true
    else
      !from_me  # If IsFromMe is false, it's incoming
    end
  end

  # This is the ID that distinguishes between conversations
  # For Evolution Go, it's the Chat field from Info
  def conversation_id
    @evolution_go_info&.dig(:Chat)
  end

  def sender_id
    if incoming?
      if group_message?
        # For group messages, get the actual sender
        @evolution_go_info&.dig(:Sender)
      else
        # For individual chats, use Chat field
        conversation_id
      end
    else
      # For outgoing messages, use the instance's phone number
      whatsapp_channel.phone_number
    end
  end

  def group_message?
    @evolution_go_info&.dig(:IsGroup) == true
  end

  def raw_message_id
    @evolution_go_info&.dig(:ID)
  end

  def phone_number_from_jid
    jid = sender_id
    return nil unless jid

    # Extract phone number from JID (e.g., "557499879409@s.whatsapp.net" -> "557499879409")
    jid.split('@').first.gsub(/:\d+$/, '')
  end

  def contact_name
    @evolution_go_info&.dig(:PushName).presence || phone_number_from_jid
  end

  def sender_alt
    @evolution_go_info&.dig(:SenderAlt)
  end

  def is_whatsapp_phone_number?
    jid = sender_id
    return false unless jid

    jid.include?('@s.whatsapp.net')
  end

  def group_jid
    conversation_id if group_message?
  end

  def group_subject
    return nil unless group_message?

    group_data = @evolution_go_data&.dig(:groupData) || {}
    group_data[:Name].presence || group_data[:Subject].presence || fallback_group_name
  end

  def fallback_group_name
    jid = conversation_id.to_s
    suffix = jid.split('@').first.to_s.split('-').last.to_s.last(4)
    suffix.present? ? "WhatsApp Group #{suffix}" : 'WhatsApp Group'
  end

  def participant_push_name
    @evolution_go_info&.dig(:PushName).presence
  end

  # Normalised media type from the EvoGo Info.MediaType field. Used to surface
  # a typed preview ("🎥 Vídeo") in the conversation list when the message is
  # media but the actual attachment failed to download or arrived inline (base64).
  def evolution_go_media_type
    case @evolution_go_info&.dig(:MediaType).to_s.downcase
    when 'image' then 'image'
    when 'video' then 'video'
    when 'audio', 'ptt' then 'audio'
    when 'document' then 'file'
    when 'sticker' then 'sticker'
    end
  end

  def whatsapp_channel
    @whatsapp_channel ||= @inbox.channel
  end

  def message_timestamp
    # Evolution Go: Parse timestamp from Info
    timestamp_str = @evolution_go_info&.dig(:Timestamp)
    return Time.current.to_i unless timestamp_str

    begin
      Time.parse(timestamp_str).to_i
    rescue ArgumentError
      Rails.logger.warn "Evolution Go API: Invalid timestamp format: #{timestamp_str}"
      Time.current.to_i
    end
  end

  def message_content
    # Evolution Go: Extract content from Message object
    message = @evolution_go_message
    return nil unless message

    # Text message
    return message[:conversation] if message[:conversation].present?

    # Extended text message
    return message.dig(:extendedTextMessage, :text) if message[:extendedTextMessage].present?

    # Other message types (media, etc.) - return nil for now
    nil
  end

  def message_type
    # Evolution Go: Use Type from Info
    @evolution_go_info&.dig(:Type)&.downcase
  end

  def message_processable?
    Rails.logger.info 'Evolution Go API: Checking if message is processable'
    Rails.logger.info "Evolution Go API: Message ID: #{raw_message_id}"
    Rails.logger.info "Evolution Go API: Is incoming: #{incoming?}"

    return false if raw_message_id.blank?
    return false unless message_content.present? || @evolution_go_message.present?

    true
  end

  def quoted_message_id
    # Evolution Go: Extract quoted message ID from different possible locations
    message = @evolution_go_message
    data = @evolution_go_data

    Rails.logger.info 'Evolution Go API: Checking for quoted message'
    Rails.logger.info "Evolution Go API: Message structure: #{message&.keys}"
    Rails.logger.info "Evolution Go API: Data structure: #{data&.keys}"
    Rails.logger.info "Evolution Go API: Data isQuoted: #{data&.dig(:isQuoted)}"
    Rails.logger.info "Evolution Go API: Has extendedTextMessage: #{message&.dig(:extendedTextMessage).present?}"
    Rails.logger.info "Evolution Go API: extendedTextMessage keys: #{message&.dig(:extendedTextMessage)&.keys}"
    Rails.logger.info "Evolution Go API: contextInfo keys: #{message&.dig(:extendedTextMessage, :contextInfo)&.keys}"

    return nil unless message

    # Check for context.id (similar to WhatsApp Cloud structure)
    quoted_id = message.dig(:context, :id)
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in context.id: #{quoted_id}"
      return quoted_id
    end

    # Check in extendedTextMessage.contextInfo.stanzaId (note: stanzaId with lowercase 'd')
    quoted_id = message.dig(:extendedTextMessage, :contextInfo, :stanzaId)
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in extendedTextMessage.contextInfo.stanzaId: #{quoted_id}"
      return quoted_id
    end

    # Check in extendedTextMessage.contextInfo.stanzaID (uppercase 'D')
    quoted_id = message.dig(:extendedTextMessage, :contextInfo, :stanzaID)
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in extendedTextMessage.contextInfo.stanzaID: #{quoted_id}"
      return quoted_id
    end

    # Check for conversation message with contextInfo
    quoted_id = message.dig(:contextInfo, :stanzaId)
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in root contextInfo.stanzaId: #{quoted_id}"
      return quoted_id
    end

    # Check for conversation message with contextInfo (uppercase)
    quoted_id = message.dig(:contextInfo, :stanzaID)
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in root contextInfo.stanzaID: #{quoted_id}"
      return quoted_id
    end

    # Check in messageContextInfo.stanzaId
    quoted_id = message.dig(:messageContextInfo, :stanzaId)
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in messageContextInfo.stanzaId: #{quoted_id}"
      return quoted_id
    end

    # Check in root level quoted.stanzaID (alternative location)
    quoted_id = data.dig(:quoted, :stanzaID) if data.present?
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in root quoted.stanzaID: #{quoted_id}"
      return quoted_id
    end

    # Check in root level quoted.stanzaId (lowercase)
    quoted_id = data.dig(:quoted, :stanzaId) if data.present?
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in root quoted.stanzaId: #{quoted_id}"
      return quoted_id
    end

    # Check for other message types with contextInfo
    %i[imageMessage videoMessage audioMessage documentMessage].each do |msg_type|
      quoted_id = message.dig(msg_type, :contextInfo, :stanzaId)
      if quoted_id.present?
        Rails.logger.info "Evolution Go API: Found quoted ID in #{msg_type}.contextInfo.stanzaId: #{quoted_id}"
        return quoted_id
      end

      quoted_id = message.dig(msg_type, :contextInfo, :stanzaID)
      if quoted_id.present?
        Rails.logger.info "Evolution Go API: Found quoted ID in #{msg_type}.contextInfo.stanzaID: #{quoted_id}"
        return quoted_id
      end
    end

    # Check for contextInfo with different key variations
    quoted_id = message.dig(:contextInfo, :quotedMessage, :key, :id)
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in contextInfo.quotedMessage.key.id: #{quoted_id}"
      return quoted_id
    end

    # Check for quotedMessage at root level
    quoted_id = message.dig(:quotedMessage, :key, :id)
    if quoted_id.present?
      Rails.logger.info "Evolution Go API: Found quoted ID in root quotedMessage.key.id: #{quoted_id}"
      return quoted_id
    end

    Rails.logger.info 'Evolution Go API: No quoted message ID found'
    nil
  end

  def quoted_message?
    # Evolution Go: Check if this is a quoted/reply message
    data = @evolution_go_data
    message = @evolution_go_message

    # Check explicit isQuoted flag
    return true if data&.dig(:isQuoted) == true

    # Check if quoted message ID exists
    return true if quoted_message_id.present?

    # Check if message has quotedMessage key (various locations)
    return true if message&.key?('quotedMessage')
    return true if message&.key?(:quotedMessage)
    return true if message&.dig(:contextInfo, :quotedMessage).present?
    return true if message&.dig(:extendedTextMessage, :contextInfo, :quotedMessage).present?

    false
  end

  def message_already_processed?
    # Check if message with this source_id already exists
    existing_message = inbox.messages.find_by(source_id: raw_message_id)
    existing_message.present?
  end

  def has_media?
    # Evolution Go: Check if message has media content
    message = @evolution_go_message
    Rails.logger.info 'Evolution Go API: Checking for media in message'
    Rails.logger.info "Evolution Go API: Message keys: #{message&.keys}"
    return false unless message

    # Check for various media types
    media_types = %i[imageMessage videoMessage audioMessage documentMessage stickerMessage]

    # Check each media type
    media_types.each do |type|
      has_type = message[type].present?
      Rails.logger.info "Evolution Go API: Has #{type}? #{has_type}"
      if has_type
        Rails.logger.info "Evolution Go API: #{type} content: #{message[type].keys if message[type].is_a?(Hash)}"
      end
    end

    has_media = media_types.any? { |type| message[type].present? }
    Rails.logger.info "Evolution Go API: Final has_media result: #{has_media}"
    has_media
  end

  def media_attachment?
    # Evolution Go: Check if message is a media type
    type = message_type
    %w[image video audio file sticker].include?(type)
  end

  def message_type
    # Evolution Go: Determine message type based on message structure
    message = @evolution_go_message
    return 'text' unless message

    if message[:conversation] || message.dig(:extendedTextMessage, :text).present?
      'text'
    elsif message[:imageMessage]
      'image'
    elsif message[:audioMessage]
      'audio'
    elsif message[:videoMessage]
      'video'
    elsif message[:documentMessage] || message[:documentWithCaptionMessage]
      'file'
    elsif message[:stickerMessage]
      'sticker'
    elsif message[:reactionMessage]
      'reaction'
    elsif message[:locationMessage]
      'location'
    elsif message[:contactMessage] || message[:contactsArrayMessage]
      'contacts'
    elsif message[:protocolMessage]
      'protocol'
    else
      'unsupported'
    end
  end
end
