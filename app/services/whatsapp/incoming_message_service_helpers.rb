module Whatsapp::IncomingMessageServiceHelpers
  def download_attachment_file(attachment_payload)
    Down.download(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
  end

  def conversation_params
    {
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    }
  end

  def processed_params
    @processed_params ||= params
  end

  def message_type
    if evolution_api?
      # Evolution API structure: data.messageType
      @processed_params[:data][:messageType]
    else
      # Baileys structure: messages.first.type
      @processed_params[:messages].first[:type]
    end
  end

  def message_content(message)
    # TODO: map interactive messages back to button messages in Evolution
    message.dig(:text, :body) ||
      message.dig(:button, :text) ||
      message.dig(:interactive, :button_reply, :title) ||
      message.dig(:interactive, :list_reply, :title) ||
      message.dig(:name, :formatted_name)
  end

  def file_content_type(file_type)
    return :image if %w[image sticker].include?(file_type)
    return :audio if %w[audio voice].include?(file_type)
    return :video if ['video'].include?(file_type)
    return :location if ['location'].include?(file_type)
    return :contact if ['contacts'].include?(file_type)

    :file
  end

  def unprocessable_message_type?(message_type)
    %w[reaction ephemeral unsupported request_welcome].include?(message_type)
  end

  def brazil_phone_number?(phone_number)
    phone_number.match(/^55/)
  end

  # ref: https://github.com/evolution/evolution/issues/5840
  def normalised_brazil_mobile_number(phone_number)
    # DDD : Area codes in Brazil are popularly known as "DDD codes" (códigos DDD) or simply "DDD", from the initials of "direct distance dialing"
    # https://en.wikipedia.org/wiki/Telephone_numbers_in_Brazil
    ddd = phone_number[2, 2]
    # Remove country code and DDD to obtain the number
    number = phone_number[4, phone_number.length - 4]
    normalised_number = "55#{ddd}#{number}"
    # insert 9 to convert the number to the new mobile number format
    normalised_number = "55#{ddd}9#{number}" if normalised_number.length != 13
    normalised_number
  end

  def processed_waid(waid)
    return waid if waid.blank? || bsuid_format?(waid)

    # in case of Brazil, we need to do additional processing
    # https://github.com/evolution/evolution/issues/5840
    if brazil_phone_number?(waid)
      # check if there is an existing contact inbox with the normalised waid
      # We will create conversation against it
      contact_inbox = inbox.contact_inboxes.find_by(source_id: normalised_brazil_mobile_number(waid))

      # if there is no contact inbox with the waid without 9,
      # We will create contact inboxes and contacts with the number 9 added
      waid = contact_inbox.source_id if contact_inbox.present?
    end
    waid
  end

  def bsuid_format?(value)
    value.present? && value.match?(RegexHelper::BSUID_REGEX)
  end

  def error_webhook_event?(message)
    message.key?('errors')
  end

  def log_error(message)
    Rails.logger.warn "Whatsapp Error: #{message['errors'][0]['title']} - contact: #{message['from']}"
  end

  def process_in_reply_to(message)
    @in_reply_to_external_id = message['context']&.[]('id')
  end

  def find_message_by_source_id(source_id)
    return unless source_id

    @message = Message.find_by(source_id: source_id)
  end

  def message_under_process?
    message_id = if evolution_api?
                   # Evolution API structure: data.key.id
                   @processed_params[:data]&.dig(:key, :id)
                 else
                   # Baileys structure: messages.first.id
                   @processed_params[:messages]&.first&.dig(:id)
                 end

    return false unless message_id

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: message_id)
    Redis::Alfred.get(key)
  end

  def cache_message_source_id_in_redis
    message_id = if evolution_api?
                   # Evolution API structure: data.key.id
                   @processed_params[:data]&.dig(:key, :id)
                 else
                   # Baileys structure: messages.first.id
                   return if @processed_params.try(:[], :messages).blank?

                   @processed_params[:messages].first[:id]
                 end

    return unless message_id

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: message_id)
    ::Redis::Alfred.setex(key, true)
  end

  def clear_message_source_id_from_redis
    message_id = if evolution_api?
                   # Evolution API structure: data.key.id
                   @processed_params[:data]&.dig(:key, :id)
                 else
                   # Baileys structure: messages.first.id
                   @processed_params[:messages].first[:id]
                 end

    return unless message_id

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: message_id)
    ::Redis::Alfred.delete(key)
  rescue StandardError => e
    # Callers release the guard from an `ensure`, where a raise here would replace the
    # exception already propagating and hide why the message failed in the first place.
    Rails.logger.error "Whatsapp: failed to clear the dedup guard for #{message_id}: #{e.message}"
  end

  private

  def evolution_api?
    # Evolution API has data structure with event field, while Baileys has messages array
    @processed_params[:data].present? && @processed_params[:event].present?
  end
end
