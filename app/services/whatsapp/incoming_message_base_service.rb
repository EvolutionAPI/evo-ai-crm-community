# Mostly modeled after the intial implementation of the service based on 360 Dialog
# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/
class Whatsapp::IncomingMessageBaseService
  include ::Whatsapp::IncomingMessageServiceHelpers

  pattr_initialize [:inbox!, :params!]

  def perform
    processed_params

    if processed_params.try(:[], :statuses).present?
      process_statuses
    elsif processed_params.try(:[], :messages).present?
      process_messages
    end
  end

  private

  def process_messages
    # We don't support reactions & ephemeral message now, we need to skip processing the message
    # if the webhook event is a reaction or an ephermal message or an unsupported message.
    return if unprocessable_message_type?(message_type)

    # Multiple webhook event can be received against the same message due to misconfigurations in the Meta
    # business manager account. While we have not found the core reason yet, the following line ensure that
    # there are no duplicate messages created.
    return if find_message_by_source_id(@processed_params[:messages].first[:id]) || message_under_process?

    cache_message_source_id_in_redis
    set_contact
    return unless @contact

    set_conversation
    create_messages
    clear_message_source_id_from_redis
  end

  def process_statuses
    return unless find_message_by_source_id(@processed_params[:statuses].first[:id])

    update_message_with_status(@message, @processed_params[:statuses].first)
    persist_bsuid_from_status
  rescue ArgumentError => e
    Rails.logger.error "Error while processing whatsapp status update #{e.message}"
  end

  def persist_bsuid_from_status
    return unless @message&.conversation&.contact_inbox

    contact_inbox = @message.conversation.contact_inbox

    # Status webhooks now include contacts[] with user_id and recipient_user_id
    bsuid = @processed_params.dig(:contacts, 0, :user_id) ||
            @processed_params[:statuses]&.first&.dig(:recipient_user_id)
    username = @processed_params.dig(:contacts, 0, :profile, :username)

    update_bsuid_fields(contact_inbox, bsuid, username)
  rescue StandardError => e
    Rails.logger.error "Error persisting BSUID from status webhook: #{e.message}"
  end

  def update_message_with_status(message, status)
    message.status = status[:status]
    if status[:status] == 'failed' && status[:errors].present?
      error = status[:errors]&.first
      message.external_error = "#{error[:code]}: #{error[:title]}"
    end
    message.save!
  end

  def create_messages
    message = @processed_params[:messages].first
    log_error(message) && return if error_webhook_event?(message)

    process_in_reply_to(message)

    message_type == 'contacts' ? create_contact_messages(message) : create_regular_message(message)
  end

  def create_contact_messages(message)
    message['contacts'].each do |contact|
      create_message(contact)
      attach_contact(contact)
      @message.save!
    end
  end

  def create_regular_message(message)
    create_message(message)
    attach_files
    attach_location if message_type == 'location'
    @message.save!
  end

  def set_contact
    contact_params = @processed_params[:contacts]&.first
    return if contact_params.blank?

    bsuid = contact_params[:user_id]
    username = contact_params.dig(:profile, :username)
    waid = contact_params[:wa_id]
    phone_from = @processed_params[:messages]&.first&.dig(:from)

    if waid.present?
      # Phone available: use existing flow
      source_id = processed_waid(waid)
      phone_number = "+#{phone_from}" if phone_from.present?
    elsif bsuid.present?
      # BSUID-only: try to find existing contact_inbox by bsuid column first
      existing_ci = inbox.contact_inboxes.find_by(bsuid: bsuid)
      if existing_ci
        @contact_inbox = existing_ci
        @contact = existing_ci.contact
        update_bsuid_fields(existing_ci, bsuid, username)
        return
      end
      source_id = bsuid
      phone_number = nil
    else
      return
    end

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: { name: contact_params.dig(:profile, :name), phone_number: phone_number }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Always persist BSUID and username when present
    update_bsuid_fields(contact_inbox, bsuid, username)
  end

  def update_bsuid_fields(contact_inbox, bsuid, username)
    return unless bsuid.present? || username.present?

    attrs = {}
    attrs[:bsuid] = bsuid if bsuid.present? && contact_inbox.bsuid != bsuid
    attrs[:whatsapp_username] = username if username.present? && contact_inbox.whatsapp_username != username
    contact_inbox.update!(attrs) if attrs.present?
  end

  def set_conversation
    # Primeiro: busca conversation existente
    @conversation = if @inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations
                                    .where.not(status: :resolved).last
                    end
    return if @conversation  # ← Se encontrou, retorna

    # Segundo: se não encontrou, cria nova usando operação atômica
    # find_or_create_by é mais seguro que create! para evitar race conditions
    @conversation = ::Conversation.find_or_create_by!(conversation_params)
  end

  def attach_files
    return if %w[text button interactive location contacts].include?(message_type)

    attachment_payload = @processed_params[:messages].first[message_type.to_sym]
    @message.content ||= attachment_payload[:caption]

    attachment_file = download_attachment_file(attachment_payload)
    return if attachment_file.blank?

    @message.attachments.new(
      file_type: file_content_type(message_type),
      file: {
        io: attachment_file,
        filename: attachment_file.original_filename,
        content_type: attachment_file.content_type
      }
    )
  end

  def attach_location
    location = @processed_params[:messages].first['location']
    location_name = location['name'] ? "#{location['name']}, #{location['address']}" : ''
    @message.attachments.new(
      file_type: file_content_type(message_type),
      coordinates_lat: location['latitude'],
      coordinates_long: location['longitude'],
      fallback_title: location_name,
      external_url: location['url']
    )
  end

  def create_message(message)
    @message = @conversation.messages.build(
      content: message_content(message),
      inbox_id: @inbox.id,
      message_type: :incoming,
      sender: @contact,
      source_id: message[:id].to_s,
      in_reply_to_external_id: @in_reply_to_external_id
    )
  end

  def attach_contact(contact)
    phones = contact[:phones]
    phones = [{ phone: 'Phone number is not available' }] if phones.blank?

    phones.each do |phone|
      @message.attachments.new(
        file_type: file_content_type(message_type),
        fallback_title: phone[:phone].to_s
      )
    end
  end

end
