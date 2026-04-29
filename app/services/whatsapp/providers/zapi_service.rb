class Whatsapp::Providers::ZapiService < Whatsapp::Providers::BaseService
  BASE_URL = 'https://api.z-api.io'

  def send_message(phone_number, message)
    @message = message
    if message.attachments.present?
      attachment = message.attachments.first
      send_attachment(phone_number, attachment, message)
    else
      send_text(phone_number, message)
    end
  end

  def send_text(phone_number, message)
    payload = {
      phone: phone_number,
      message: html_to_whatsapp(message.content.to_s)
    }

    # Add reply context if exists - Z-API uses messageId in the same payload
    reply_context = zapi_reply_context(message)
    if reply_context.present?
      payload[:messageId] = reply_context[:messageId]
    end

    response = HTTParty.post(
      "#{base_url}/send-text",
      headers: api_headers_with_client_token,
      body: payload.to_json
    )

    process_response(response)
  end

  def send_attachment(phone_number, attachment, message)
    file_url = attachment.file_url
    caption = html_to_whatsapp(message.content.to_s)

    case attachment.file_type
    when 'image'
      send_image(phone_number, file_url, caption, message)
    when 'video'
      send_video(phone_number, file_url, caption, message)
    when 'audio'
      send_audio(phone_number, file_url, message)
    else
      send_document(phone_number, file_url, attachment.file.filename.to_s, caption, message)
    end
  end

  def send_image(phone_number, image_url, caption = '', message = nil)
    @message = message
    payload = {
      phone: phone_number,
      image: image_url
    }
    payload[:caption] = caption if caption.present?

    reply_context = zapi_reply_context(message)
    if reply_context.present?
      payload[:messageId] = reply_context[:messageId]
    end

    response = HTTParty.post(
      "#{base_url}/send-image",
      headers: api_headers_with_client_token,
      body: payload.to_json
    )

    process_response(response)
  end

  def send_video(phone_number, video_url, caption = '', message = nil)
    @message = message
    payload = {
      phone: phone_number,
      video: video_url
    }
    payload[:caption] = caption if caption.present?

    reply_context = zapi_reply_context(message)
    if reply_context.present?
      payload[:messageId] = reply_context[:messageId]
    end

    response = HTTParty.post(
      "#{base_url}/send-video",
      headers: api_headers_with_client_token,
      body: payload.to_json
    )

    process_response(response)
  end

  def send_audio(phone_number, audio_url, message = nil)
    @message = message
    payload = {
      phone: phone_number,
      audio: audio_url
    }

    reply_context = zapi_reply_context(message)
    if reply_context.present?
      payload[:messageId] = reply_context[:messageId]
    end

    response = HTTParty.post(
      "#{base_url}/send-audio",
      headers: api_headers_with_client_token,
      body: payload.to_json
    )

    process_response(response)
  end

  def send_document(phone_number, document_url, filename = '', caption = '', message = nil)
    @message = message
    payload = {
      phone: phone_number,
      document: document_url
    }
    payload[:fileName] = filename if filename.present?
    payload[:caption] = caption if caption.present?

    reply_context = zapi_reply_context(message)
    if reply_context.present?
      payload[:messageId] = reply_context[:messageId]
    end

    response = HTTParty.post(
      "#{base_url}/send-document",
      headers: api_headers_with_client_token,
      body: payload.to_json
    )

    process_response(response)
  end


  def delete_message(phone_number, message_id)
    payload = {
      phone: phone_number,
      messageId: message_id
    }

    response = HTTParty.post(
      "#{base_url}/delete-message",
      headers: api_headers_with_client_token,
      body: payload.to_json
    )

    process_response(response)
  end

  # Z-API does not support template sending via API
  def send_template(_phone_number, _template_info, _message = nil)
    Rails.logger.warn 'Z-API: Templates are not supported via API'
    nil
  end

  # Z-API does not support template sync via API
  def sync_templates
    Rails.logger.info 'Z-API: Template sync is not available. Manage templates in Meta Business Manager.'
  end

  # Configure Z-API webhooks via API
  def subscribe_to_webhooks
    webhook_url = callback_url
    Rails.logger.info "Z-API: Configuring webhooks for instance #{whatsapp_channel.provider_config['instance_id']}"
    Rails.logger.info "Z-API: Webhook URL: #{webhook_url}"

    instance_id = whatsapp_channel.provider_config['instance_id']
    token = whatsapp_channel.provider_config['token']
    client_token = whatsapp_channel.provider_config['client_token']

    return false if instance_id.blank? || token.blank?

    # Configure each webhook individually
    # Based on Z-API documentation:
    # - on-message-send: update-webhook-delivery
    # - on-message-received: update-webhook-received
    # - on-whatsapp-disconnected: update-webhook-disconnected
    # - on-webhook-connected: update-webhook-connected
    # - update-notify-sent-by-me: update-notify-sent-by-me
    results = []
    results << configure_webhook(instance_id, token, client_token, 'update-webhook-delivery', webhook_url)
    results << configure_webhook(instance_id, token, client_token, 'update-webhook-received', webhook_url)
    results << configure_webhook(instance_id, token, client_token, 'update-webhook-disconnected', webhook_url)
    results << configure_webhook(instance_id, token, client_token, 'update-webhook-connected', webhook_url)
    results << configure_webhook(instance_id, token, client_token, 'update-notify-sent-by-me', webhook_url, true)

    success_count = results.count(true)
    Rails.logger.info "Z-API: Configured #{success_count}/#{results.size} webhooks successfully"
    success_count > 0
  rescue StandardError => e
    Rails.logger.error "Z-API: Webhook configuration error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end

  def unsubscribe_from_webhooks
    # Z-API doesn't have a direct unsubscribe endpoint
    # Webhooks can be cleared by setting them to empty string
    Rails.logger.info "Z-API: Clearing webhooks for instance #{whatsapp_channel.provider_config['instance_id']}"

    instance_id = whatsapp_channel.provider_config['instance_id']
    token = whatsapp_channel.provider_config['token']
    client_token = whatsapp_channel.provider_config['client_token']

    return false if instance_id.blank? || token.blank?

    # Clear all webhooks
    results = []
    results << configure_webhook(instance_id, token, client_token, 'update-webhook-delivery', '')
    results << configure_webhook(instance_id, token, client_token, 'update-webhook-received', '')
    results << configure_webhook(instance_id, token, client_token, 'update-webhook-disconnected', '')
    results << configure_webhook(instance_id, token, client_token, 'update-webhook-connected', '')
    results << configure_webhook(instance_id, token, client_token, 'update-notify-sent-by-me', '', true)

    success_count = results.count(true)
    Rails.logger.info "Z-API: Cleared #{success_count}/#{results.size} webhooks"
    success_count > 0
  rescue StandardError => e
    Rails.logger.error "Z-API: Webhook unsubscription error: #{e.message}"
    false
  end

  def validate_provider_config?
    # Validate by checking required fields are present
    # Similar to Evolution Go, we don't make API calls during validation
    # The actual credentials will be validated when trying to use the channel
    Rails.logger.info "Z-API: Starting validation. provider_config: #{whatsapp_channel.provider_config.inspect}"
    Rails.logger.info "Z-API: provider_config class: #{whatsapp_channel.provider_config.class}"

    # Handle both string keys and symbol keys
    provider_config = whatsapp_channel.provider_config || {}
    instance_id = provider_config['instance_id'] || provider_config[:instance_id]
    token = provider_config['token'] || provider_config[:token]
    client_token = provider_config['client_token'] || provider_config[:client_token]

    Rails.logger.info "Z-API: Extracted instance_id: #{instance_id.inspect}, token: #{token.inspect}, client_token: #{client_token.present? ? 'present' : 'blank'}"

    if instance_id.blank?
      Rails.logger.error "Z-API validation error: instance_id is blank. provider_config keys: #{provider_config.keys.inspect}"
      return false
    end

    if token.blank?
      Rails.logger.error "Z-API validation error: token is blank. provider_config keys: #{provider_config.keys.inspect}"
      return false
    end

    if client_token.blank?
      Rails.logger.error "Z-API validation error: client_token is blank. provider_config keys: #{provider_config.keys.inspect}"
      return false
    end

    Rails.logger.info "Z-API validation passed - all required fields present (instance_id: #{instance_id})"
    true
  rescue StandardError => e
    Rails.logger.error "Z-API validation error: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end

  private

  def configure_webhook(instance_id, token, client_token, endpoint, webhook_url, is_notify = false)
    # Z-API endpoints:
    # PUT /instances/{INSTANCE}/token/{TOKEN}/update-webhook-delivery
    # PUT /instances/{INSTANCE}/token/{TOKEN}/update-webhook-received
    # PUT /instances/{INSTANCE}/token/{TOKEN}/update-webhook-disconnected
    # PUT /instances/{INSTANCE}/token/{TOKEN}/update-webhook-connected
    # PUT /instances/{INSTANCE}/token/{TOKEN}/update-notify-sent-by-me
    url = "#{BASE_URL}/instances/#{instance_id}/token/#{token}/#{endpoint}"

    # For notify-sent-by-me, the payload structure is different
    # According to Z-API docs: { "notifySentByMe": true }
    payload = if is_notify
                { notifySentByMe: true } # Enable notifications for messages sent by me
              else
                { value: webhook_url }
              end

    headers = {
      'Content-Type' => 'application/json'
    }
    headers['Client-Token'] = client_token if client_token.present?

    response = HTTParty.put(
      url,
      headers: headers,
      body: payload.to_json
    )

    if response.success?
      Rails.logger.info "Z-API: Successfully configured webhook #{endpoint} to #{webhook_url.presence || 'disabled'}"
      true
    else
      Rails.logger.error "Z-API: Failed to configure webhook #{endpoint}. Status: #{response.code}, Body: #{response.body}"
      false
    end
  rescue StandardError => e
    Rails.logger.error "Z-API: Error configuring webhook #{endpoint}: #{e.message}"
    false
  end

  def api_headers
    {
      'Content-Type' => 'application/json'
    }
  end

  def media_url(_media_id)
    # Z-API sends direct URLs in webhooks
    nil
  end

  def error_message(response)
    parsed = response.parsed_response

    # Handle case where parsed_response is a String
    if parsed.is_a?(String)
      return parsed.presence || response.body.presence || 'Failed to send'
    end

    # Handle case where parsed_response is nil or not a Hash
    return response.body.presence || 'Failed to send' unless parsed.is_a?(Hash)

    # Try to extract error message from nested structure
    if parsed['error'].is_a?(Hash)
      parsed['error']['message'] || parsed['error'].to_s
    else
      parsed['message'] ||
        parsed['error'] ||
        response.body.presence ||
        'Failed to send'
    end
  end

  def process_response(response)
    parsed_response = response.parsed_response

    # Handle case where parsed_response is nil or not a Hash
    unless parsed_response.is_a?(Hash)
      handle_error(response)
      return nil
    end

    if response.success? && parsed_response['error'].blank?
      store_message_ids(parsed_response)
      # Z-API returns messageId or id
      parsed_response['messageId'] || parsed_response['id'] || parsed_response['zaapId']
    else
      handle_error(response)
      nil
    end
  end

  def handle_error(response)
    parsed = response.parsed_response
    store_message_ids(parsed) if parsed.is_a?(Hash)
    super
  end

  def store_message_ids(parsed_response)
    return unless @message
    return unless parsed_response.is_a?(Hash)

    message_id = parsed_response['messageId'] || parsed_response['id']
    zaap_id = parsed_response['zaapId']

    updates = {}
    external_ids = @message.external_source_ids || {}

    external_ids['zapi_message_id'] = message_id if message_id.present?
    external_ids['zapi_zaap_id'] = zaap_id if zaap_id.present?

    updates[:external_source_ids] = external_ids if external_ids != @message.external_source_ids
    updates[:source_id] = message_id if message_id.present?

    @message.update_columns(updates) if updates.any?
  end

  private

  def base_url
    # Z-API sempre usa a mesma URL base
    instance_id = whatsapp_channel.provider_config['instance_id']
    token = whatsapp_channel.provider_config['token']
    "#{BASE_URL}/instances/#{instance_id}/token/#{token}"
  end

  def api_headers_with_client_token
    headers = api_headers
    # Client-Token é um token separado do token da instância
    client_token = whatsapp_channel.provider_config['client_token']
    headers['Client-Token'] = client_token if client_token.present?
    headers
  end

  def callback_url
    # Priority: BACKEND_URL > EVOAI_URL > FRONTEND_URL — at least one must be configured.
    api_url = ENV['BACKEND_URL'].presence ||
              ENV['EVOAI_URL'].presence ||
              ENV['FRONTEND_URL'].presence
    raise 'BACKEND_URL/EVOAI_URL/FRONTEND_URL is not configured (required to register Z-API webhook callback)' if api_url.blank?

    "#{api_url.chomp('/')}/webhooks/whatsapp/zapi"
  end

  def zapi_reply_context(message)
    return {} unless message

    reply_msg_id = message.content_attributes[:in_reply_to]
    reply_to = message.content_attributes[:in_reply_to_external_id]

    if reply_msg_id.present?
      msg = Message.find_by(id: reply_msg_id)
      zapi_message_id = msg&.external_source_ids&.[]('zapi_message_id')
      reply_to = zapi_message_id if zapi_message_id.present?
    end

    return {} if reply_to.blank?

    { messageId: reply_to }
  end
end
