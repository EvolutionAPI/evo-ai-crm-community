require 'base64'
require 'tempfile'

module Whatsapp::EvolutionGoHandlers::MessagesUpsert
  include Whatsapp::EvolutionGoHandlers::Helpers
  include Whatsapp::EvolutionGoHandlers::ProfilePictureHandler

  private

  def handle_message
    return unless message_processable?

    Rails.logger.info "Evolution Go API: Creating new message #{raw_message_id}"

    set_contact
    return unless @contact_inbox

    set_conversation
    update_conversation_status_if_needed
    create_message(attach_media: media_attachment?)
  end

  def set_contact
    Rails.logger.info "Evolution Go API: Setting contact - inbox present: #{inbox.present?}"

    if incoming?
      set_contact_for_incoming
    else
      set_contact_for_outgoing
    end
  end

  def set_contact_for_incoming
    push_name = contact_name
    phone_number = phone_number_from_jid
    sender_alt_value = sender_alt
    is_whatsapp_number = is_whatsapp_phone_number?

    source_id = determine_source_id(sender_alt_value, phone_number)

    Rails.logger.info "Evolution Go API: Incoming contact - source_id: #{source_id}, phone_number: #{phone_number}, push_name: #{push_name}"

    contact_attributes = build_contact_attributes(push_name, phone_number, sender_alt_value, is_whatsapp_number)

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: contact_attributes
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    update_contact_information(push_name, phone_number, sender_alt_value, is_whatsapp_number)
    update_contact_profile_picture(@contact, phone_number)

    Rails.logger.info "Evolution Go API: Contact set - ID: #{@contact.id}, Name: #{@contact.name}, Identifier: #{@contact.identifier}, Source ID: #{@contact_inbox.source_id}"
  end

  def set_contact_for_outgoing
    # Para mensagens IsFromMe (eco do celular), identificar o contato pelo Chat LID
    # que coincide com o identifier gravado no contato durante o incoming
    chat_lid = conversation_id

    Rails.logger.info "Evolution Go API: Outgoing echo - looking up contact by identifier: #{chat_lid}"

    contact_inbox = inbox.contact_inboxes
                         .joins(:contact)
                         .find_by(contacts: { identifier: chat_lid })

    if contact_inbox
      @contact_inbox = contact_inbox
      @contact = contact_inbox.contact
      Rails.logger.info "Evolution Go API: Found contact #{@contact.id} (#{@contact.name}) via identifier for outgoing echo"
      return
    end

    # Fallback: tentar pelo RecipientAlt (telefone real do contato)
    recipient_alt = @evolution_go_info&.dig(:RecipientAlt)
    if recipient_alt.present?
      phone = recipient_alt.split('@').first.gsub(/:\d+$/, '')
      contact_inbox = inbox.contact_inboxes
                           .joins(:contact)
                           .find_by(contacts: { phone_number: "+#{phone}" })
      if contact_inbox
        @contact_inbox = contact_inbox
        @contact = contact_inbox.contact
        Rails.logger.info "Evolution Go API: Found contact #{@contact.id} via RecipientAlt #{phone} for outgoing echo"
        return
      end
    end

    Rails.logger.warn "Evolution Go API: No existing contact found for outgoing echo (Chat: #{chat_lid}). Skipping message."
    @contact_inbox = nil
    @contact = nil
  end

  def determine_source_id(sender_alt_value, phone_number)
    if sender_alt_value.present?
      Rails.logger.info "Evolution Go API: Using SenderAlt '#{sender_alt_value}' as source_id"
      sender_alt_value
    else
      Rails.logger.info "Evolution Go API: Using phone_number '#{phone_number}' as source_id (no SenderAlt available)"
      phone_number
    end
  end

  def build_contact_attributes(push_name, phone_number, sender_alt_value, is_whatsapp_number)
    attributes = {
      name: push_name
    }

    # Use SenderAlt as identifier if available
    attributes[:identifier] = sender_alt_value if sender_alt_value.present?

    # Only set phone_number if it's a WhatsApp phone number (@s.whatsapp.net)
    attributes[:phone_number] = "+#{phone_number}" if is_whatsapp_number

    attributes
  end

  def update_contact_information(push_name, phone_number, sender_alt_value, is_whatsapp_number)
    updates = {}

    # Update contact name if it was just the phone number
    updates[:name] = push_name if @contact.name == phone_number && push_name.present?

    # Update identifier with SenderAlt if contact doesn't have one and SenderAlt is present
    if @contact.identifier.blank? && sender_alt_value.present?
      updates[:identifier] = sender_alt_value
      Rails.logger.info "Evolution Go API: Adding identifier #{sender_alt_value} to existing contact #{@contact.id}"
    end

    # Update phone_number if contact only has number without identifier and this is a WhatsApp number
    if @contact.phone_number.blank? && is_whatsapp_number
      updates[:phone_number] = "+#{phone_number}"
      Rails.logger.info "Evolution Go API: Adding phone_number +#{phone_number} to contact #{@contact.id}"
    end

    # Apply all updates in a single database call
    @contact.update!(updates) if updates.any?
  end

  def update_conversation_status_if_needed
    return if incoming?
    return unless @conversation&.status == 'pending'
    return if @conversation.inbox.active_bot?

    @conversation.update!(status: :open)
    Rails.logger.info "Evolution Go API: Updated conversation #{@conversation.id} from pending to open (outgoing from phone)"
  end

  def create_message(attach_media: false)
    Rails.logger.info "Evolution Go API: Creating message with content: #{message_content}"
    Rails.logger.info "Evolution Go API: Attach media flag: #{attach_media}"

    # Check if this is a quoted/reply message
    reply_to_id = quoted_message_id
    is_quoted = quoted_message?

    Rails.logger.info "Evolution Go API: Is quoted message? #{is_quoted}"
    Rails.logger.info "Evolution Go API: Message is a reply to: #{reply_to_id}" if reply_to_id.present?
    Rails.logger.info 'Evolution Go API: No reply ID found for quoted message' if is_quoted && reply_to_id.blank?

    # Build message attributes (like Evolution v2)
    build_message_attributes(@conversation, reply_to_id)

    # Handle media attachment if needed
    handle_attach_media if attach_media

    # Save message
    @message.save!

    Rails.logger.info "Evolution Go API: Message saved - ID: #{@message.id}, Reply attributes: #{@message.content_attributes.slice(:in_reply_to,
                                                                                                                                   :in_reply_to_external_id)}"
    Rails.logger.info "Evolution Go API: Message created successfully - ID: #{@message.id}, Content: #{@message.content&.truncate(100)}"

    # Notify like Evolution v2
    inbox.channel.received_messages([@message], @message.conversation) if incoming?
  end

  def build_message_attributes(conversation, reply_to_id = nil)
    content_attrs = message_content_attributes

    # Add reply information if this is a quoted message
    if reply_to_id.present?
      content_attrs[:in_reply_to_external_id] = reply_to_id
      Rails.logger.info "Evolution Go API: Adding reply reference to content_attributes: #{reply_to_id}"
    end

    message_attributes = {
      inbox_id: @inbox.id,
      content: message_content || '',
      source_id: raw_message_id,
      created_at: Time.zone.at(message_timestamp),
      sender: incoming? ? @contact : (User.where(type: 'SuperAdmin').first || User.first),
      sender_type: incoming? ? 'Contact' : 'User',
      message_type: incoming? ? :incoming : :outgoing,
      content_attributes: content_attrs
    }

    @message = conversation.messages.build(message_attributes)

    Rails.logger.info "Evolution Go API: Message built with attributes: #{message_attributes.keys}"
    Rails.logger.info "Evolution Go API: Message content_attributes: #{@message.content_attributes}"
  end

  def handle_attach_media
    Rails.logger.info "Evolution Go API: Processing attachment for message #{raw_message_id}, type: #{message_type}"

    debug_media_info
    attachment_file = download_attachment_file
    return unless attachment_file

    create_attachment(attachment_file)
  rescue Down::Error => e
    @message.update!(is_unsupported: true)
    Rails.logger.error "Evolution Go API: Failed to download attachment for message #{raw_message_id}: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Failed to create attachment for message #{raw_message_id}: #{e.message}"
    Rails.logger.error "  - Error class: #{e.class}"
    Rails.logger.error "  - Error details: #{e.inspect}"
  end

  def media_message?
    # Evolution Go: Check if it's a media message
    return false unless @evolution_go_info

    media_type = @evolution_go_info[:MediaType]
    message_type = @evolution_go_info[:Type]

    # Media types in Evolution Go: image, video, audio, document
    media_type.present? || message_type == 'media'
  end

  def message_content
    # Evolution Go: Extract content based on message type
    return nil unless @evolution_go_message

    message = @evolution_go_message

    # Text messages
    return message[:conversation] if message[:conversation].present?

    # Extended text messages
    return message.dig(:extendedTextMessage, :text) if message.dig(:extendedTextMessage, :text).present?

    # Media captions
    caption = extract_media_caption
    return caption if caption.present?

    # Empty content for media without caption
    return '' if media_message?

    nil
  end

  def extract_media_caption
    message = @evolution_go_message
    return nil unless message

    # Try to extract caption from different media types
    message.dig(:imageMessage, :caption) ||
      message.dig(:videoMessage, :caption) ||
      message.dig(:audioMessage, :caption) ||
      message.dig(:documentMessage, :caption)
  end

  def extract_media_url
    # Evolution Go provides processed mediaUrl directly at Message level
    message = @evolution_go_message
    Rails.logger.info 'Evolution Go API: Extracting media URL from message'
    Rails.logger.info "Evolution Go API: Message structure for media: #{message&.keys}"
    return nil unless message

    # Evolution Go structure has mediaUrl at the root Message level
    media_url = message[:mediaUrl]
    Rails.logger.info "Evolution Go API: Root level mediaUrl: #{media_url}"

    # Fallback: check inside specific message types if not found at root
    if media_url.blank?
      Rails.logger.info 'Evolution Go API: Checking inside specific message types for mediaUrl'

      image_url = message.dig(:imageMessage, :mediaUrl)
      video_url = message.dig(:videoMessage, :mediaUrl)
      audio_url = message.dig(:audioMessage, :mediaUrl)
      doc_url = message.dig(:documentMessage, :mediaUrl)
      sticker_url = message.dig(:stickerMessage, :mediaUrl)

      Rails.logger.info "Evolution Go API: imageMessage.mediaUrl: #{image_url}"
      Rails.logger.info "Evolution Go API: videoMessage.mediaUrl: #{video_url}"
      Rails.logger.info "Evolution Go API: audioMessage.mediaUrl: #{audio_url}"
      Rails.logger.info "Evolution Go API: documentMessage.mediaUrl: #{doc_url}"
      Rails.logger.info "Evolution Go API: stickerMessage.mediaUrl: #{sticker_url}"

      media_url = image_url || video_url || audio_url || doc_url || sticker_url
    end

    Rails.logger.info "Evolution Go API: Final extracted media URL: #{media_url}"
    media_url
  end

  def extract_filename_from_url(url)
    # Try to extract filename from URL
    filename = File.basename(URI.parse(url).path)

    # If no extension or generic filename, generate one
    if File.extname(filename).blank? || filename == File.basename(filename, '.*')
      extension = determine_file_extension
      filename = "#{raw_message_id}#{extension}"
    end

    filename
  end

  def determine_content_type
    return 'text/plain' unless @evolution_go_message

    message = @evolution_go_message

    if message[:imageMessage]
      message.dig(:imageMessage, :mimetype) || 'image/jpeg'
    elsif message[:videoMessage]
      message.dig(:videoMessage, :mimetype) || 'video/mp4'
    elsif message[:audioMessage]
      message.dig(:audioMessage, :mimetype) || 'audio/ogg'
    elsif message[:documentMessage]
      message.dig(:documentMessage, :mimetype) || 'application/pdf'
    else
      'text/plain'
    end
  end

  def determine_file_extension
    # Evolution Go: Extract extension from MediaType
    media_type = @evolution_go_info[:MediaType]

    case media_type
    when 'image'
      '.jpg'
    when 'video'
      '.mp4'
    when 'audio', 'ptt'  # PTT is audio in Evolution Go
      '.ogg'  # PTT files are usually OGG format
    when 'document'
      '.pdf'
    else
      '.bin'
    end
  end

  def file_content_type
    # EXACTLY like Evolution v2: based on message type, not MediaType
    msg_type = message_type_from_media

    return :image if msg_type.in?(%w[image sticker])
    return :video if msg_type == 'video'
    return :audio if msg_type == 'audio'
    return :location if msg_type == 'location'
    return :contact if msg_type == 'contacts'

    :file
  end

  def message_type_from_media
    # Convert Evolution Go MediaType to message_type like Evolution v2
    media_type = @evolution_go_info[:MediaType]

    case media_type
    when 'image'
      'image'
    when 'video'
      'video'
    when 'audio', 'ptt'  # PTT (push-to-talk) is audio in Evolution v2
      'audio'
    when 'document'
      'file'
    else
      'file'
    end
  end

  def message_content_attributes
    {
      external_created_at: message_timestamp
    }
  end

  def configure_audio_metadata(attachment)
    return unless attachment

    audio_message = @evolution_go_message&.dig(:audioMessage)
    return unless audio_message

    meta = { is_recorded_audio: audio_message[:ptt].present? }
    meta[:duration] = audio_message[:seconds].to_i if audio_message[:seconds].present?
    meta[:file_length] = audio_message[:fileLength].to_i if audio_message[:fileLength].present?

    if audio_message[:waveform].present?
      meta[:waveform] = audio_message[:waveform]
      Rails.logger.info "Evolution Go API: Audio waveform extracted (#{audio_message[:waveform].length} chars)"
    end

    attachment.update!(content_attributes: meta) if meta.any?
  end

  def audio_voice_note?
    @evolution_go_info[:MediaType] == 'ptt'
  end

  def create_attachment(attachment_file)
    final_filename = generate_filename_with_extension
    final_content_type = determine_content_type

    log_attachment_info(attachment_file, final_filename, final_content_type)

    blob = ActiveStorage::Blob.create_and_upload!(
      io: attachment_file,
      filename: final_filename,
      content_type: final_content_type
    )

    attachment = @message.attachments.build(file_type: file_content_type.to_s)
    attachment.file.attach(blob)

    configure_audio_metadata(attachment) if audio_voice_note?
    log_attachment_success(attachment)
  end

  def download_attachment_file
    message = @evolution_go_message

    if message[:mediaUrl].present?
      Rails.logger.info "Evolution Go API: Downloading from mediaUrl: #{message[:mediaUrl]}"
      return Down.download(message[:mediaUrl])
    end

    Rails.logger.warn 'Evolution Go API: No media found - no mediaUrl'
    nil
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Failed to download media: #{e.message}"
    nil
  end

  def debug_media_info
    Rails.logger.info 'Evolution Go API: Media debug info:'
    Rails.logger.info "- Message type: #{message_type}"
    Rails.logger.info "- Media URL: #{@evolution_go_message[:mediaUrl]}"
    Rails.logger.info "- Mimetype: #{message_mimetype}"
  end

  def log_attachment_info(attachment_file, filename, content_type)
    Rails.logger.info 'Evolution Go API: Creating attachment:'
    Rails.logger.info "- Filename: #{filename}"
    Rails.logger.info "- Content type: #{content_type}"
    Rails.logger.info "- File size: #{attachment_file.size} bytes"
  end

  def log_attachment_success(attachment)
    Rails.logger.info "Evolution Go API: Attachment created successfully with ID: #{attachment.id}"
  end

  def generate_filename_with_extension
    existing_filename = filename
    return existing_filename if existing_filename.present? && File.extname(existing_filename).present?

    base_name = existing_filename.presence || "#{message_type}_#{raw_message_id}_#{Time.current.strftime('%Y%m%d')}"
    extension = file_extension

    "#{base_name}#{extension}"
  end

  def file_extension
    case message_type
    when 'image'
      image_extension
    when 'video'
      video_extension
    when 'audio'
      audio_extension
    when 'file'
      document_extension
    when 'sticker'
      '.webp'
    else
      '.bin'
    end
  end

  def image_extension
    extension_map = {
      /jpeg/ => '.jpg',
      /png/ => '.png',
      /gif/ => '.gif',
      /webp/ => '.webp'
    }

    extension_map.each { |pattern, ext| return ext if message_mimetype&.match?(pattern) }
    '.jpg' # Fallback for images
  end

  def video_extension
    extension_map = {
      /mp4/ => '.mp4',
      /webm/ => '.webm',
      /avi/ => '.avi'
    }

    extension_map.each { |pattern, ext| return ext if message_mimetype&.match?(pattern) }
    '.mp4' # Fallback for videos
  end

  def audio_extension
    extension_map = {
      /mp3/ => '.mp3',
      /wav/ => '.wav',
      /ogg/ => '.ogg',
      /aac/ => '.aac',
      /opus/ => '.opus'
    }

    extension_map.each { |pattern, ext| return ext if message_mimetype&.match?(pattern) }
    '.mp3' # Fallback for audio files
  end

  def document_extension
    filename_from_message = @evolution_go_message.dig(:documentMessage, :fileName) ||
                            @evolution_go_message.dig(:documentWithCaptionMessage, :message, :documentMessage, :fileName)
    return File.extname(filename_from_message) if filename_from_message.present?

    extension_map = {
      /pdf/ => '.pdf',
      /doc/ => '.doc',
      /zip/ => '.zip'
    }

    extension_map.each { |pattern, ext| return ext if message_mimetype&.match?(pattern) }
    '.bin' # Fallback for document files
  end

  def filename
    filename = @evolution_go_message.dig(:documentMessage, :fileName) ||
               @evolution_go_message.dig(:documentWithCaptionMessage, :message, :documentMessage, :fileName)
    return filename if filename.present?

    ext = ".#{message_mimetype.split(';').first.split('/').last}" if message_mimetype.present?
    "#{file_content_type}_#{raw_message_id}_#{Time.current.strftime('%Y%m%d')}#{ext}"
  end

  def message_mimetype
    case message_type
    when 'image'
      @evolution_go_message.dig(:imageMessage, :mimetype)
    when 'sticker'
      @evolution_go_message.dig(:stickerMessage, :mimetype)
    when 'video'
      @evolution_go_message.dig(:videoMessage, :mimetype)
    when 'audio'
      @evolution_go_message.dig(:audioMessage, :mimetype)
    when 'file'
      @evolution_go_message.dig(:documentMessage, :mimetype) ||
        @evolution_go_message.dig(:documentWithCaptionMessage, :message, :documentMessage, :mimetype)
    end
  end
end


