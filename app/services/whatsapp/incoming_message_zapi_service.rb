class Whatsapp::IncomingMessageZapiService
  include Whatsapp::IncomingMessageServiceHelpers

  pattr_initialize [:inbox!, :params!]

  # Map Z-API status codes to internal message states
  STATUS_MAP = {
    'SENT' => 'sent',
    'RECEIVED' => 'delivered',
    'READ' => 'read',
    'READ_BY_ME' => 'read',
    'PLAYED' => 'read'
  }.freeze

  def perform
    case params[:type]
    when 'MessageStatusCallback'
      process_status_update
    when 'ReceivedCallback'
      if params[:fromMe]
        # This is a confirmation of a message we sent
        # If it has referenceMessageId, we should update our sent message to link it as a reply
        process_sent_message_confirmation if params[:referenceMessageId].present?
      else
        process_incoming_message
      end
    when 'ConnectedCallback'
      process_connection_event
    when 'DisconnectedCallback'
      process_disconnection_event
    end
  rescue StandardError => e
    Rails.logger.error "Z-API processing error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  private

  def process_status_update
    message_id = params[:ids]&.first || params[:messageId]
    return unless message_id.present?

    # Find message by Z-API message ID
    message = Message.where("external_source_ids ->> 'zapi_message_id' = ?", message_id).first
    message ||= Message.find_by(source_id: message_id)

    unless message
      Rails.logger.info "Z-API status webhook message not found: #{message_id}"
      return
    end

    status_code = params[:status].to_s.upcase
    status = STATUS_MAP[status_code] || 'sent'

    Messages::StatusUpdateService.new(message, status, nil).perform

    # Update contact last seen for read status
    if status == 'read'
      timestamp = Time.at(params[:moment] / 1000.0).utc
      conversation = message.conversation
      conversation.update!(contact_last_seen_at: timestamp)
      ::Conversations::UpdateMessageStatusJob.perform_later(conversation.id, timestamp, :read)
    elsif status == 'delivered'
      timestamp = Time.at(params[:moment] / 1000.0).utc
      ::Conversations::UpdateMessageStatusJob.perform_later(message.conversation_id, timestamp, :delivered)
    end
  rescue StandardError => e
    Rails.logger.error "Z-API status update error: #{e.message}"
  end

  def process_incoming_message
    phone = params[:phone]
    chat_lid = params[:chatLid]
    message_id = params[:messageId]
    timestamp = params[:momment] || params[:moment] || Time.current.to_i * 1000

    # Mirror EVO-1018's Evolution-path handling (EvolutionHandlers::MessagesUpsert#set_group_contact):
    # a group becomes a contact of type 'group' identified by the group JID, with no phone_number.
    #
    # Two Z-API quirks have to be normalized for a group, otherwise the message is silently dropped
    # (the WhatsappEventsJob rescue swallows the validation error and never reaches Sentry):
    #   1. params[:phone] is the group JID "<digits>-group", not an E.164 number — forcing
    #      "+#{phone}" makes Contact#save! raise on the phone E.164 validation.
    #   2. ContactInbox#source_id is validated against a regex that, for groups, only accepts the
    #      "<digits>@g.us" shape — "<digits>-group" is rejected. Normalize it the same way the
    #      Evolution path already produces its group JIDs.
    if params[:isGroup]
      group_jid = "#{phone.to_s.sub(/-group\z/, '')}@g.us"
      source_id = group_jid
      identifier = group_jid
      contact_attributes = { name: params[:chatName] || params[:senderName], identifier: identifier, type: 'group' }
    else
      source_id = chat_lid.presence || phone
      identifier = chat_lid.presence
      contact_attributes = { name: params[:chatName] || params[:senderName], identifier: identifier, phone_number: "+#{phone}" }
    end

    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      source_id: source_id,
      contact_attributes: contact_attributes
    ).perform

    # Fetch contact profile picture if not already set (groups have no contact phone number)
    fetch_contact_profile_picture(contact_inbox.contact, "+#{phone}") unless params[:isGroup] || contact_inbox.contact.avatar.attached?

    conversation = find_or_create_conversation(contact_inbox)

    # Process different message types
    if params[:text].present?
      process_text_message(conversation, contact_inbox, message_id, timestamp)
    elsif params[:image].present?
      process_image_message(conversation, contact_inbox, message_id, timestamp)
    elsif params[:video].present?
      process_video_message(conversation, contact_inbox, message_id, timestamp)
    elsif params[:audio].present?
      process_audio_message(conversation, contact_inbox, message_id, timestamp)
    elsif params[:document].present?
      process_document_message(conversation, contact_inbox, message_id, timestamp)
    elsif params[:location].present?
      process_location_message(conversation, contact_inbox, message_id, timestamp)
    elsif params[:contact].present?
      process_contact_message(conversation, contact_inbox, message_id, timestamp)
    end
  rescue StandardError => e
    Rails.logger.error "Z-API incoming message error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  def find_or_create_conversation(contact_inbox)
    conversation = if inbox.lock_to_single_conversation
                     contact_inbox.conversations.last
                   else
                     contact_inbox.conversations.where.not(status: :resolved).last
                   end
    conversation ||= Conversation.create!(
      inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id
    )
    conversation
  end

  def process_text_message(conversation, contact_inbox, message_id, timestamp)
    content = params.dig(:text, :message) || params.dig(:text, :text)

    message = create_message(
      conversation: conversation,
      contact_inbox: contact_inbox,
      content: content,
      message_id: message_id,
      timestamp: timestamp
    )

    message.save!
  end

  def process_image_message(conversation, contact_inbox, message_id, timestamp)
    image_data = params[:image]
    caption = image_data[:caption] || image_data[:text]

    message = create_message(
      conversation: conversation,
      contact_inbox: contact_inbox,
      content: caption,
      message_id: message_id,
      timestamp: timestamp
    )

    attach_file(message, image_data[:imageUrl], 'image', image_data[:mimeType])
    message.save!
  end

  def process_video_message(conversation, contact_inbox, message_id, timestamp)
    video_data = params[:video]
    caption = video_data[:caption] || video_data[:text]

    message = create_message(
      conversation: conversation,
      contact_inbox: contact_inbox,
      content: caption,
      message_id: message_id,
      timestamp: timestamp
    )

    attach_file(message, video_data[:videoUrl], 'video', video_data[:mimeType])
    message.save!
  end

  def process_audio_message(conversation, contact_inbox, message_id, timestamp)
    audio_data = params[:audio]

    message = create_message(
      conversation: conversation,
      contact_inbox: contact_inbox,
      content: '',
      message_id: message_id,
      timestamp: timestamp
    )

    attach_file(message, audio_data[:audioUrl], 'audio', audio_data[:mimeType])
    message.save!
  end

  def process_document_message(conversation, contact_inbox, message_id, timestamp)
    document_data = params[:document]
    caption = document_data[:caption] || document_data[:text]

    message = create_message(
      conversation: conversation,
      contact_inbox: contact_inbox,
      content: caption,
      message_id: message_id,
      timestamp: timestamp
    )

    attach_file(
      message,
      document_data[:documentUrl],
      'file',
      document_data[:mimeType],
      document_data[:fileName]
    )
    message.save!
  end

  def process_location_message(conversation, contact_inbox, message_id, timestamp)
    location_data = params[:location]

    message = create_message(
      conversation: conversation,
      contact_inbox: contact_inbox,
      content: '',
      message_id: message_id,
      timestamp: timestamp
    )

    attach_location(message, location_data)
    message.save!
  end

  def process_contact_message(conversation, contact_inbox, message_id, timestamp)
    contact_data = params[:contact]

    message = create_message(
      conversation: conversation,
      contact_inbox: contact_inbox,
      content: message_content(contact_data),
      message_id: message_id,
      timestamp: timestamp
    )

    attach_contact(message, contact_data)
    message.save!
  end

  def create_message(conversation:, contact_inbox:, content:, message_id:, timestamp:)
    message = conversation.messages.new(
      content: content,
      inbox_id: inbox.id,
      message_type: :incoming,
      sender: contact_inbox.contact,
      source_id: message_id
    )

    # Store Z-API message IDs
    external_ids = message.external_source_ids || {}
    external_ids['zapi_message_id'] = message_id if message_id.present?
    message.external_source_ids = external_ids

    # Handle quoted/reply messages
    handle_reply_context(message, conversation)

    message
  end

  def process_sent_message_confirmation
    # When we receive confirmation of a message we sent with reply,
    # update the message to ensure it has the correct reply context
    message_id = params[:messageId]
    reference_message_id = params[:referenceMessageId]

    return unless message_id.present? && reference_message_id.present?

    # Find the message we sent
    sent_message = Message.where("external_source_ids ->> 'zapi_message_id' = ?", message_id).first
    sent_message ||= Message.find_by(source_id: message_id)

    return unless sent_message

    # Find the original message being replied to
    reply_msg = Message
                      .where("external_source_ids ->> 'zapi_message_id' = ?", reference_message_id).first
    reply_msg ||= Message
                         .where("external_source_ids ->> 'zapi_zaap_id' = ?", reference_message_id).first
    reply_msg ||= Message.find_by(source_id: reference_message_id)

    if reply_msg && sent_message.content_attributes[:in_reply_to].blank?
      attrs = sent_message.content_attributes.merge(
        in_reply_to: reply_msg.id,
        in_reply_to_external_id: reference_message_id
      )
      sent_message.update_column(:content_attributes, attrs)
    end
  end

  def handle_reply_context(message, conversation)
    # Z-API provides referenceMessageId in webhooks for reply messages
    reference_message_id = params[:referenceMessageId]
    return if reference_message_id.blank?

    # Try multiple search strategies to find the original message
    reply_msg = conversation.messages.where("external_source_ids ->> 'zapi_message_id' = ?", reference_message_id).first
    reply_msg ||= conversation.messages.where("external_source_ids ->> 'zapi_zaap_id' = ?", reference_message_id).first
    reply_msg ||= conversation.messages.find_by(source_id: reference_message_id)

    # If not found in conversation, search in account messages
    if reply_msg.nil?
      reply_msg = Message
                        .where("external_source_ids ->> 'zapi_message_id' = ?", reference_message_id).first
      reply_msg ||= Message
                           .where("external_source_ids ->> 'zapi_zaap_id' = ?", reference_message_id).first
      reply_msg ||= Message.find_by(source_id: reference_message_id)
    end

    if reply_msg
      attrs = message.content_attributes.merge(in_reply_to_external_id: reference_message_id)
      attrs[:in_reply_to] = reply_msg.id
      message.assign_attributes(content_attributes: attrs)

      # Ensure the original message has its zapi_message_id stored
      if reply_msg.external_source_ids&.[]('zapi_message_id').blank? && reference_message_id.present?
        external_ids = reply_msg.external_source_ids || {}
        external_ids['zapi_message_id'] = reference_message_id
        reply_msg.update_column(:external_source_ids, external_ids)
      end

      reply_msg.update_column(:source_id, reference_message_id) if reply_msg.source_id.blank?
    else
      # Still set the external_id even if we can't find the message
      attrs = message.content_attributes.merge(in_reply_to_external_id: reference_message_id)
      message.assign_attributes(content_attributes: attrs)
    end
  end

  def fetch_contact_profile_picture(contact, phone_number)
    return unless inbox.channel.is_a?(Channel::Whatsapp)
    return unless inbox.channel.provider == 'zapi'

    whatsapp_channel = inbox.channel
    provider_config = whatsapp_channel.provider_config
    instance_id = provider_config['instance_id']
    token = provider_config['token']
    client_token = provider_config['client_token']

    return unless instance_id.present? && token.present? && client_token.present?

    # Remove + from phone number for Z-API
    phone_without_plus = phone_number.gsub(/^\+/, '')

    profile_picture_url = fetch_profile_picture_from_zapi(instance_id, token, client_token, phone_without_plus)

    if profile_picture_url.present?
      Avatar::AvatarFromUrlJob.perform_later(contact, profile_picture_url)
    end
  rescue StandardError => e
    Rails.logger.error "Z-API: Failed to fetch profile picture for contact #{contact.id}: #{e.message}"
  end

  def fetch_profile_picture_from_zapi(instance_id, token, client_token, phone_number)
    api_url = 'https://api.z-api.io'
    url = "#{api_url}/instances/#{instance_id}/token/#{token}/profile-picture?phone=#{phone_number}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['Client-Token'] = client_token if client_token.present?
    request['Content-Type'] = 'application/json'

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "Z-API: Profile picture request failed - Status: #{response.code}"
      return nil
    end

    response_data = JSON.parse(response.body)
    profile_picture_url = response_data['link']

    if profile_picture_url.present?
      profile_picture_url
    else
      nil
    end
  rescue JSON::ParserError => e
    Rails.logger.error "Z-API: Profile picture response JSON parse error: #{e.message}"
    nil
  rescue StandardError => e
    Rails.logger.error "Z-API: Profile picture request error: #{e.class} - #{e.message}"
    nil
  end

  def attach_file(message, file_url, file_type, mime_type, filename = nil)
    return if file_url.blank?

    io = Down.download(file_url)
    filename ||= File.basename(io.path)

    message.attachments.new(
      file_type: file_content_type(file_type),
      fallback_title: filename,
      file: {
        io: io,
        filename: filename,
        content_type: mime_type
      }
    )
  rescue StandardError => e
    Rails.logger.error "Z-API file attach error: #{e.message}"
  end

  def attach_location(message, location_data)
    location_name = [location_data[:name], location_data[:address]].compact.join(', ')

    message.attachments.new(
      file_type: :location,
      coordinates_lat: location_data[:latitude],
      coordinates_long: location_data[:longitude],
      fallback_title: location_name,
      external_url: location_data[:url]
    )
  end

  def attach_contact(message, contact_data)
    phones = contact_phones(contact_data)
    phones = [{ phone: 'Phone number is not available' }] if phones.blank?

    phones.each do |phone|
      message.attachments.new(
        file_type: file_content_type('contacts'),
        fallback_title: phone[:phone].to_s,
        meta: {
          display_name: contact_data[:displayName] || contact_data[:name]
        }
      )
    end
  end

  def process_connection_event
    Rails.logger.info "Z-API: Instance connected - instanceId: #{params[:instanceId]}, phone: #{params[:phone]}, lid: #{params[:lid]}"

    # Update channel connection status
    inbox.channel.update_provider_connection!({
      connection: 'open',
      error: nil
    })

    # Fetch and update inbox avatar with Z-API profile picture
    fetch_inbox_profile_picture(params[:phone]) if params[:phone].present?
  rescue StandardError => e
    Rails.logger.error "Z-API: Error in process_connection_event: #{e.message}"
  end

  def fetch_inbox_profile_picture(phone_number)
    Rails.logger.info "Z-API: fetch_inbox_profile_picture called with phone: #{phone_number}"

    return unless inbox.channel.is_a?(Channel::Whatsapp)
    return unless inbox.channel.provider == 'zapi'

    Rails.logger.info "Z-API: Channel is Z-API, proceeding with profile picture fetch"

    whatsapp_channel = inbox.channel
    provider_config = whatsapp_channel.provider_config
    instance_id = provider_config['instance_id']
    token = provider_config['token']
    client_token = provider_config['client_token']

    Rails.logger.info "Z-API: Config - instance_id: #{instance_id}, token: #{token.present? ? 'present' : 'missing'}, client_token: #{client_token.present? ? 'present' : 'missing'}"

    return unless instance_id.present? && token.present? && client_token.present?

    # Remove + from phone number for Z-API
    phone_without_plus = phone_number.gsub(/^\+/, '')

    Rails.logger.info "Z-API: Fetching profile picture for phone: #{phone_without_plus}"

    profile_picture_url = fetch_profile_picture_from_zapi(instance_id, token, client_token, phone_without_plus)

    if profile_picture_url.present?
      Rails.logger.info "Z-API: Profile picture URL found: #{profile_picture_url}, scheduling job for inbox #{inbox.id}"
      Avatar::AvatarFromUrlJob.perform_later(inbox, profile_picture_url)
    else
      Rails.logger.info "Z-API: No profile picture URL found for inbox #{inbox.id}"
    end
  rescue StandardError => e
    Rails.logger.error "Z-API: Failed to fetch inbox profile picture: #{e.message}"
  end

  def process_disconnection_event
    Rails.logger.warn "Z-API: Instance disconnected - instanceId: #{params[:instanceId]}, error: #{params[:error]}"

    # Update channel connection status
    error_message = params[:error].present? ? "Z-API: #{params[:error]}" : nil
    inbox.channel.update_provider_connection!({
      connection: 'close',
      error: error_message
    })
  rescue StandardError => e
    Rails.logger.error "Z-API: Error in process_disconnection_event: #{e.message}"
  end
end
