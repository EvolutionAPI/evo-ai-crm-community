class Whatsapp::ConversationSyncService
  include Rails.application.routes.url_helpers
  include ::Whatsapp::IncomingMessageServiceHelpers

  pattr_initialize [:inbox!, :params!]

  def perform
    return unless valid_sync_event?

    if history_sync_event?
      process_history_sync
    elsif message_echo_event?
      process_message_echo
    end
  end

  private

  def valid_sync_event?
    # Check for history sync or message echo events
    history_sync_event? || message_echo_event?
  end

  def history_sync_event?
    params.dig(:entry, 0, :changes, 0, :field) == 'history'
  end

  def message_echo_event?
    params.dig(:entry, 0, :changes, 0, :field) == 'smb_message_echoes'
  end

  def process_history_sync
    value = params.dig(:entry, 0, :changes, 0, :value)

    # Handle errors if present
    return handle_history_sync_error if value[:history]&.dig(0, :errors).present?

    # Support both webhook formats from Meta documentation:
    # 1. Simple format: value.messages (single messages)
    # 2. Threaded format: value.history[].threads[].messages (conversation threads)

    if value[:messages].present?
      # Format 1: Simple messages array (e.g., single audio message)
      Rails.logger.info "[WHATSAPP] Processing simple history format with #{value[:messages].size} messages"
      process_simple_messages(value[:messages])

    elsif value[:history].present?
      # Format 2: Threaded history with conversation threads
      Rails.logger.info "[WHATSAPP] Processing threaded history format with #{value[:history].size} history items"
      process_threaded_history(value[:history])

    else
      Rails.logger.warn '[WHATSAPP] No messages or history found in sync webhook'
    end
  end

  def process_simple_messages(messages)
    # Handle simple messages array format
    messages.each do |message_data|
      create_message_from_history(message_data)
    end
  end

  def process_threaded_history(history_data)
    # Handle threaded conversation history format
    history_data.each do |history_item|
      next if history_item[:threads].blank?

      history_item[:threads].each do |thread|
        next if thread[:messages].blank?

        phone_number = thread[:id] # Thread ID is the phone number
        Rails.logger.info "[WHATSAPP] Processing thread #{phone_number} with #{thread[:messages].size} messages"

        thread[:messages].each do |message_data|
          create_message_from_history(message_data, phone_number)
        end
      end
    end
  end

  def handle_history_sync_error
    error_info = params.dig(:entry, 0, :changes, 0, :value, :history, 0, :errors, 0)
    Rails.logger.warn "[WHATSAPP] History sync declined or failed: #{error_info[:message]}"
  end

  def create_message_from_history(message_data, thread_phone_number = nil)
    return unless valid_message_data?(message_data)

    # Use thread phone number if provided (threaded format), otherwise extract from message (simple format)
    phone_number = thread_phone_number || message_data[:from]

    return if phone_number.blank?

    contact_inbox = find_or_create_contact_inbox(phone_number)
    return unless contact_inbox

    conversation = find_or_create_conversation(contact_inbox)
    return unless conversation

    create_historical_message(message_data, conversation, contact_inbox.contact, phone_number)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Failed to create historical message: #{e.message}"
  end

  def process_message_echo
    message_echoes = params.dig(:entry, 0, :changes, 0, :value, :message_echoes) || []

    message_echoes.each do |echo_data|
      create_echo_message(echo_data)
    end
  end

  def create_echo_message(echo_data)
    return unless valid_echo_data?(echo_data)

    to_phone_number = echo_data[:to]
    echo_data[:from]

    # Find the contact this message was sent to
    contact_inbox = find_contact_inbox_by_phone(to_phone_number)
    return unless contact_inbox

    conversation = find_or_create_conversation(contact_inbox)
    return unless conversation

    # Create outgoing message (sent from business via WhatsApp Business App)
    create_echo_message_record(echo_data, conversation, contact_inbox.contact)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Failed to create echo message: #{e.message}"
  end

  def valid_message_data?(message_data)
    message_data[:id].present? &&
      message_data[:from].present? &&
      message_data[:timestamp].present? &&
      message_data[:type].present?
  end

  def valid_echo_data?(echo_data)
    echo_data[:id].present? &&
      echo_data[:to].present? &&
      echo_data[:from].present? &&
      echo_data[:timestamp].present? &&
      echo_data[:type].present?
  end

  def find_or_create_contact_inbox(phone_number)
    contact_inbox = inbox.contact_inboxes.find_by(source_id: phone_number)
    return contact_inbox if contact_inbox

    # Create contact if not exists
    ::ContactInboxWithContactBuilder.new(
      source_id: phone_number,
      inbox: inbox,
      contact_attributes: {
        name: format_phone_number(phone_number),
        phone_number: format_phone_number(phone_number),
        additional_attributes: {
          whatsapp_history_synced: true
        }
      }
        ).perform

    contact_inbox
  end

  def find_contact_inbox_by_phone(phone_number)
    # For echo messages, we need to find contact by their WhatsApp ID (without +)
    inbox.contact_inboxes.find_by(source_id: phone_number)
  end

  def find_or_create_conversation(contact_inbox)
    # Look for existing conversation or create new one
    conversation = if inbox.lock_to_single_conversation
                     contact_inbox.conversations.last
                   else
                     contact_inbox.conversations.where.not(status: :resolved).last
                   end

    return conversation if conversation

    ::Conversation.create!(
      inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      additional_attributes: {
        whatsapp_history_synced: true
      }
    )
  end

  def create_historical_message(message_data, conversation, contact, _phone_number)
    # Skip if message already exists
    return if conversation.messages.find_by(source_id: message_data[:id])

    message_content = extract_message_content(message_data)
    external_timestamp = Time.zone.at(message_data[:timestamp].to_i)
    is_incoming = determine_message_direction(message_data)

    # Add computed values to message_data for build method
    enhanced_data = message_data.merge(
      computed_content: message_content,
      computed_timestamp: external_timestamp,
      computed_incoming: is_incoming
    )

    message = build_historical_message(enhanced_data, conversation, contact)
    attach_media_content(message, message_data)

    message.save!
    Rails.logger.info "[WHATSAPP] Historical message synced: #{message_data[:id]} (#{is_incoming ? 'incoming' : 'outgoing'})"
  end

  def determine_message_direction(message_data)
    business_phone_number = params.dig(:entry, 0, :changes, 0, :value, :metadata, :display_phone_number)
    is_from_business = message_data[:from] == business_phone_number ||
                       message_data.dig(:history_context, :from_me) == true

    !is_from_business
  end

  def build_historical_message(enhanced_data, conversation, contact)
    conversation.messages.build(
      content: enhanced_data[:computed_content],
      inbox_id: inbox.id,
      message_type: enhanced_data[:computed_incoming] ? :incoming : :outgoing,
      sender: enhanced_data[:computed_incoming] ? contact : nil,
      source_id: enhanced_data[:id],
      created_at: enhanced_data[:computed_timestamp],
      content_attributes: build_content_attributes(enhanced_data[:computed_timestamp], enhanced_data)
    )
  end

  def build_content_attributes(external_timestamp, message_data)
    {
      external_created_at: external_timestamp.iso8601,
      whatsapp_history_synced: true,
      whatsapp_history_context: message_data[:history_context]
    }
  end

  def attach_media_content(message, message_data)
    case message_data[:type]
    when 'image', 'audio', 'video', 'document'
      attach_media_from_history(message, message_data)
    when 'location'
      attach_location_from_history(message, message_data)
    when 'media_placeholder'
      handle_media_placeholder(message)
    end
  end

  def handle_media_placeholder(message)
    message.content = 'Media message (not available in history sync)'
    message.content_attributes[:is_media_placeholder] = true
  end

  def create_echo_message_record(echo_data, conversation, _contact)
    # Skip if message already exists
    return if conversation.messages.find_by(source_id: echo_data[:id])

    message_content = extract_message_content(echo_data)
    external_timestamp = Time.zone.at(echo_data[:timestamp].to_i)

    message = conversation.messages.build(
      content: message_content,
      inbox_id: inbox.id,
      message_type: :outgoing, # This is a message sent by the business
      sender: nil, # Business messages don't have a sender contact
      source_id: echo_data[:id],
      created_at: external_timestamp,
      content_attributes: {
        external_created_at: external_timestamp.iso8601,
        whatsapp_echo_message: true
      }
    )

    # Attach media content for echo messages
    attach_echo_media_content(message, echo_data)

    message.save!
    Rails.logger.info "[WHATSAPP] Echo message synced: #{echo_data[:id]}"
  end

  def attach_echo_media_content(message, echo_data)
    case echo_data[:type]
    when 'image', 'audio', 'video', 'document'
      attach_echo_media_file(message, echo_data)
    when 'location'
      attach_echo_location(message, echo_data)
    end
  end

  def attach_echo_media_file(message, echo_data)
    media_data = echo_data[echo_data[:type].to_sym] || {}
    media_id = media_data[:id]

    return unless media_id

    begin
      process_echo_media_download(message, echo_data, media_data, media_id)
    rescue StandardError => e
      handle_echo_media_error(message, echo_data, media_id, e)
    end
  end

  def process_echo_media_download(message, echo_data, media_data, media_id)
    attachment_file = download_echo_attachment_file(media_id)
    return unless attachment_file

    create_echo_media_attachment(message, echo_data, media_data, attachment_file)
    update_message_content_with_caption(message, media_data)

    Rails.logger.info "[WHATSAPP] Echo media attached: #{echo_data[:type]} (#{media_id})"
  end

  def create_echo_media_attachment(message, echo_data, media_data, attachment_file)
    file_type = file_content_type(echo_data[:type])
    content_type = media_data[:mime_type] || determine_content_type_from_file_type(echo_data[:type])
    filename = media_data[:filename] || generate_echo_filename(echo_data, content_type)

    message.attachments.build(
      file_type: file_type.to_s,
      file: {
        io: attachment_file,
        filename: filename,
        content_type: content_type
      }
    )
  end

  def update_message_content_with_caption(message, media_data)
    message.content = media_data[:caption] if media_data[:caption].present?
  end

  def handle_echo_media_error(message, echo_data, media_id, error)
    Rails.logger.error "[WHATSAPP] Failed to attach echo media #{media_id}: #{error.message}"
    attach_echo_media_info_fallback(message, echo_data)
  end

  def determine_content_type_from_file_type(file_type)
    content_types = {
      'image' => 'image/jpeg',
      'audio' => 'audio/mpeg',
      'video' => 'video/mp4',
      'document' => 'application/octet-stream'
    }

    content_types[file_type] || 'application/octet-stream'
  end

  def generate_echo_filename(echo_data, content_type)
    extension = determine_file_extension(content_type, echo_data)
    "echo_#{echo_data[:type]}_#{echo_data[:id]}_#{Time.current.strftime('%Y%m%d')}#{extension}"
  end

  def determine_file_extension(content_type, echo_data)
    extension_map = {
      %r{image/jpeg} => '.jpg',
      %r{image/png} => '.png',
      %r{audio/mpeg} => '.mp3',
      %r{audio/ogg} => '.ogg',
      %r{video/mp4} => '.mp4',
      %r{application/pdf} => '.pdf'
    }

    extension_map.each { |pattern, ext| return ext if content_type&.match?(pattern) }

    # Fallback to filename extension if available
    existing_filename = echo_data.dig(echo_data[:type].to_sym, :filename)
    File.extname(existing_filename || '') || '.bin'
  end

  def download_echo_attachment_file(media_id)
    # Use the same method as other WhatsApp services for downloading media
    download_attachment_file({ id: media_id })
  end

  def attach_echo_location(message, echo_data)
    location = echo_data[:location] || {}

    message.attachments.build(
      file_type: :location,
      coordinates_lat: location[:latitude],
      coordinates_long: location[:longitude],
      fallback_title: location[:name] || 'Shared location',
      external_url: location[:url]
    )
  end

  def attach_echo_media_info_fallback(message, echo_data)
    # If media download fails, store media info in content_attributes
    media_data = echo_data[echo_data[:type].to_sym] || {}

    message.content_attributes[:media_info] = {
      type: echo_data[:type],
      caption: media_data[:caption],
      filename: media_data[:filename],
      mime_type: media_data[:mime_type],
      sha256: media_data[:sha256],
      id: media_data[:id]
    }

    Rails.logger.warn "[WHATSAPP] Echo media stored as info only: #{echo_data[:type]}"
  end

  def extract_message_content(message_data)
    message_type = message_data[:type]

    case message_type
    when 'text'
      extract_text_content(message_data)
    when 'image', 'audio', 'video', 'document'
      extract_media_content(message_data, message_type)
    when 'location'
      extract_location_content(message_data)
    when 'media_placeholder'
      'Media message (not available in history sync)'
    else
      message_type&.humanize || 'Message'
    end
  end

  def extract_text_content(message_data)
    message_data.dig(:text, :body)
  end

  def extract_media_content(message_data, message_type)
    content_map = {
      'image' => 'Image message',
      'audio' => 'Audio message',
      'video' => 'Video message',
      'document' => 'Document message'
    }

    caption_key = message_type.to_sym
    message_data.dig(caption_key, :caption) || content_map[message_type]
  end

  def extract_location_content(message_data)
    location = message_data[:location]
    "Location: #{location[:name] || 'Shared location'}"
  end

  def attach_media_from_history(message, message_data)
    # NOTE: Historical media might not be available for download
    # We'll just record the media info in content_attributes
    media_data = message_data[message_data[:type].to_sym] || {}

    message.content_attributes[:media_info] = {
      type: message_data[:type],
      caption: media_data[:caption],
      filename: media_data[:filename],
      mime_type: media_data[:mime_type],
      sha256: media_data[:sha256],
      id: media_data[:id]
    }
  end

  def attach_location_from_history(message, message_data)
    location = message_data[:location] || {}

    message.content_attributes[:location_info] = {
      latitude: location[:latitude],
      longitude: location[:longitude],
      name: location[:name],
      address: location[:address],
      url: location[:url]
    }
  end

  def format_phone_number(phone_number)
    phone_number.start_with?('+') ? phone_number : "+#{phone_number}"
  end

  def account
    RuntimeConfig.account
  end
end
