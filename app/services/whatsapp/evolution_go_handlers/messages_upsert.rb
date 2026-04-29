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
    create_message(attach_media: media_attachment?)
  end

  def set_contact
    if group_message?
      set_group_contact
    else
      set_individual_contact
    end
  end

  def set_group_contact
    Rails.logger.info "Evolution Go API: Setting group contact - jid: #{group_jid}, subject: #{group_subject}"

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: group_jid,
      inbox: inbox,
      contact_attributes: {
        name: group_subject,
        identifier: group_jid
      }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    if group_subject.present? && @contact.name != group_subject
      Rails.logger.info "Evolution Go API: Updating group name #{@contact.name.inspect} -> #{group_subject.inspect}"
      @contact.update!(name: group_subject)
    end

    Rails.logger.info "Evolution Go API: Group contact set - ID: #{@contact.id}, Name: #{@contact.name}, Identifier: #{@contact.identifier}, Source ID: #{@contact_inbox.source_id}"
  end

  def set_individual_contact
    Rails.logger.info "Evolution Go API: Setting contact - inbox present: #{inbox.present?}"
    Rails.logger.info "Evolution Go API: Inbox details: #{inbox.inspect}" if inbox

    push_name = contact_name
    phone_number = phone_number_from_jid
    sender_alt_value = sender_alt
    is_whatsapp_number = is_whatsapp_phone_number?

    # Determine source_id: use identifier (SenderAlt) if available, otherwise phone_number
    source_id = determine_source_id(sender_alt_value, phone_number)

    Rails.logger.info "Evolution Go API: Creating contact with source_id: #{source_id}, phone_number: #{phone_number}, push_name: #{push_name}, sender_alt: #{sender_alt_value}, is_whatsapp: #{is_whatsapp_number}"

    # Build contact attributes with new logic
    contact_attributes = build_contact_attributes(push_name, phone_number, sender_alt_value, is_whatsapp_number)

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: contact_attributes
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Update contact with additional information
    update_contact_information(push_name, phone_number, sender_alt_value, is_whatsapp_number)

    # Update contact profile picture if not already attached
    update_contact_profile_picture(@contact, phone_number)

    Rails.logger.info "Evolution Go API: Contact set - ID: #{@contact.id}, Name: #{@contact.name}, Identifier: #{@contact.identifier}, Source ID: #{@contact_inbox.source_id}"
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

  def create_message(attach_media: false)
    Rails.logger.info "Evolution Go API: Creating message with content: #{message_content}"
    Rails.logger.info "Evolution Go API: Attach media flag: #{attach_media}"

    # Check if this is a quoted/reply message
    reply_to_id = quoted_message_id
    is_quoted = quoted_message?

    Rails.logger.info "Evolution Go API: Is quoted message? #{is_quoted}"
    Rails.logger.info "Evolution Go API: Message is a reply to: #{reply_to_id}" if reply_to_id.present?
    Rails.logger.info 'Evolution Go API: No reply ID found for quoted message' if is_quoted && reply_to_id.blank?

    # Find or create conversation
    conversation = find_or_create_conversation

    # Build message attributes (like Evolution v2)
    build_message_attributes(conversation, reply_to_id)

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
      sender: @contact,
      sender_type: 'Contact',
      message_type: :incoming,
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

  def save_message_and_notify
    @message.save!

    Rails.logger.info "Evolution Go API: Message created successfully - ID: #{@message.id}, Content: #{@message.content&.truncate(100)}"
    Rails.logger.info "Evolution Go API: Final reply attributes: #{@message.content_attributes.slice(:in_reply_to, :in_reply_to_external_id)}"

    # Notify like Evolution v2
    inbox.channel.received_messages([@message], @message.conversation) if incoming?
  end

  def find_or_create_conversation
    # Try to find existing conversation
    conversation = @contact_inbox.conversations.last

    if conversation.blank?
      Rails.logger.info "Evolution Go API: Creating new conversation for contact #{@contact.id}"

      # Create new conversation if none exists
      conversation = ::Conversation.create!(
        inbox_id: inbox.id,
        contact_id: @contact.id,
        contact_inbox_id: @contact_inbox.id,
        additional_attributes: {
          evolution_go_chat_id: conversation_id
        }
      )
    else
      Rails.logger.info "Evolution Go API: Using existing conversation #{conversation.id}"
    end

    conversation
  end

  def attach_media_from_url(media_url)
    # Download and attach media file
    Rails.logger.info 'Evolution Go API: Media attachment debug info:'
    Rails.logger.info "- Media URL: #{media_url}"
    Rails.logger.info "- Message ID: #{@message.id}"
    Rails.logger.info "- Content Type: #{determine_content_type}"

    file_name = File.basename(media_url.split('?').first)
    file_name = "#{SecureRandom.hex(8)}.#{get_file_extension}" if file_name.blank?

    Rails.logger.info "- File name: #{file_name}"

    response = HTTParty.get(media_url, timeout: 30)

    if response.success?
      Rails.logger.info 'Evolution Go API: File download successful:'
      Rails.logger.info "- Response code: #{response.code}"
      Rails.logger.info "- Content length: #{response.body.bytesize} bytes"
      Rails.logger.info "- Content type from header: #{response.headers['content-type']}"

      temp_file = Tempfile.new([File.basename(file_name, '.*'), File.extname(file_name)])
      temp_file.binmode
      temp_file.write(response.body)
      temp_file.rewind

      attachment = @message.attachments.new(
        account: nil,
        file_type: determine_attachment_file_type
      )

      attachment.file.attach(
        io: temp_file,
        filename: file_name,
        content_type: determine_content_type
      )

      Rails.logger.info 'Evolution Go API: Attachment created successfully:'
      Rails.logger.info "- Attachment ID: #{attachment.id}"
      Rails.logger.info "- File attached: #{attachment.file.attached?}"
      Rails.logger.info "- File size: #{attachment.file.byte_size} bytes" if attachment.file.attached?

      # Configure audio metadata if applicable
      configure_audio_metadata(attachment) if determine_content_type.start_with?('audio/')

      temp_file.close
      temp_file.unlink
    else
      Rails.logger.error "Evolution Go API: Failed to download media: #{response.code} - #{response.message}"
    end
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Media attachment error: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join('\n')
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
    attrs = { external_created_at: message_timestamp }
    attrs[:sender_name] = participant_push_name if group_message? && participant_push_name.present?
    attrs[:media_type] = evolution_go_media_type if evolution_go_media_type.present?
    attrs
  end

  def configure_audio_metadata(attachment)
    return unless attachment

    audio_message = @evolution_go_message['audioMessage']
    return unless audio_message

    meta = {}

    # Duration in seconds
    meta[:duration] = audio_message['seconds'].to_i if audio_message['seconds'].present?

    # Waveform data if available
    if audio_message['waveform'].present?
      meta[:waveform] = audio_message['waveform']
      Rails.logger.info "Evolution Go API: Audio waveform extracted (#{audio_message['waveform'].length} chars)"
    end

    meta[:file_length] = audio_message['fileLength'].to_i if audio_message['fileLength'].present?

    attachment.update!(content_attributes: meta) if meta.any?
  end

  def audio_voice_note?
    # Evolution Go: Check if it's a PTT voice note (like Evolution v2)
    media_type = @evolution_go_info[:MediaType]

    # Voice notes in Evolution Go have MediaType 'ptt'
    media_type == 'ptt'
  end

  def create_attachment(attachment_file)
    final_filename = generate_filename_with_extension
    final_content_type = determine_content_type

    log_attachment_info(attachment_file, final_filename, final_content_type)

    attachment = @message.attachments.build(
      file_type: file_content_type.to_s,
      file: {
        io: attachment_file,
        filename: final_filename,
        content_type: final_content_type
      }
    )

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

  def configure_audio_metadata(attachment)
    attachment.meta = { is_recorded_audio: true } if message_type == 'audio' && @evolution_go_message.dig(:audioMessage, :ptt)
  end

  def audio_voice_note?
    message_type == 'audio' && @evolution_go_message.dig(:audioMessage, :ptt)
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


