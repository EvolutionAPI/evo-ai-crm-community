class Whatsapp::Providers::NotificameService < Whatsapp::Providers::BaseService
  include Whatsapp::Providers::Concerns::TemplateSync
  
  BASE_URL = ENV.fetch('NOTIFICAME_BASE_URL', 'https://api.notificame.com.br/v1')

  def self.list_channels(api_token)
    response = HTTParty.get(
      "#{BASE_URL}/channels",
      headers: {
        'X-Api-Token' => api_token,
        'Content-Type' => 'application/json'
      }
    )
    return [] unless response.success?

    parsed = response.parsed_response
    if parsed.is_a?(Hash) && parsed['data']
      parsed['data']
    elsif parsed.is_a?(Array)
      parsed
    else
      []
    end
  rescue StandardError => e
    Rails.logger.error "Notificame list channels error: #{e.message}"
    []
  end

  def send_message(phone_number, message)
    @message = message
    if message.attachments.present?
      attachment = message.attachments.first
      type = attachment.file_type == 'file' ? 'document' : attachment.file_type
      send_file(
        phone_number,
        attachment.file_url,
        caption: html_to_whatsapp(message.outgoing_content.to_s),
        file_mime_type: type,
        filename: attachment.file.filename.to_s,
        reply_to: message
      )
    else
      payload = build_payload(phone_number, message)
      reply_ctx = notificame_reply_context(message, phone_number)
      payload.merge!(reply_ctx) if reply_ctx.present?

      response = HTTParty.post(
        "#{BASE_URL}/channels/whatsapp/messages",
        headers: api_headers,
        body: payload.to_json
      )

      process_response(response)
    end
  end

  def send_file(phone_number, file_url, caption: '', file_mime_type: 'document', filename: nil, reply_to: nil)
    file_content = {
      type: 'file',
      fileMimeType: file_mime_type,
      fileUrl: file_url
    }
    file_content[:fileName] = filename if filename.present?
    file_content[:fileCaption] = caption if caption.present?

    payload = {
      from: channel_id,
      to: phone_number,
      contents: [file_content]
    }
    reply_ctx = notificame_reply_context(reply_to, phone_number)
    payload.merge!(reply_ctx) if reply_ctx.present?
    response = HTTParty.post(
      "#{BASE_URL}/channels/whatsapp/messages",
      headers: api_headers,
      body: payload.to_json
    )
    process_response(response)
  end

  def send_template(phone_number, template_info, message = nil)
    @message = message
    payload = {
      from: channel_id,
      to: phone_number,
      contents: [
        {
          type: 'template',
          template: {
            name: template_info[:name],
            components: [
              {
                type: 'BODY',
                parameters: template_info[:parameters] || []
              }
            ],
            language: { code: template_info[:lang_code] }
          }
        }
      ]
    }
    reply_ctx = notificame_reply_context(message, phone_number)
    payload.merge!(reply_ctx) if reply_ctx.present?

    response = HTTParty.post(
      "#{BASE_URL}/channels/whatsapp/messages",
      headers: api_headers,
      body: payload.to_json
    )

    process_response(response)
  end

  def sync_templates
    templates = fetch_templates
    return if templates.blank?

    # Sincronizar templates na nova tabela
    templates.each do |template_data|
      sync_template_to_database(template_data)
    end
  rescue StandardError => e
    Rails.logger.error "Notificame sync_templates error: #{e.message}"
  end

  def create_template(template_data)
    # Notificame: Store template both internally and merge with external ones
    Rails.logger.info "Notificame: Creating template internally - #{template_data['name']}"
    
    current_templates = whatsapp_channel.message_templates || []
    # Ensure current_templates is always an array (fix for existing data)
    current_templates = [] unless current_templates.is_a?(Array)
    
    # Create internal template structure
    internal_template = {
      'id' => SecureRandom.uuid,
      'name' => template_data['name'],
      'category' => template_data['category'],
      'language' => template_data['language'],
      'status' => 'APPROVED', # Notificame internal templates are always approved
      'components' => template_data['components'],
      'created_at' => Time.current.iso8601,
      'updated_at' => Time.current.iso8601,
      'source' => 'internal' # Mark as internal template
    }
    
    # Add to existing templates (keeping external ones from API)
    current_templates << internal_template
    
    # Update channel with new template (skip validations to avoid provider_config issues)
    unless whatsapp_channel.update_columns(
      message_templates: current_templates,
      message_templates_last_updated: Time.current
    )
      Rails.logger.error "Notificame: Failed to save template - #{whatsapp_channel.errors.full_messages}"
      raise "Failed to save template: #{whatsapp_channel.errors.full_messages.join(', ')}"
    end
    
    Rails.logger.info "Notificame: Template created internally with ID #{internal_template['id']}"
    internal_template
  end

  def update_template(template_id, template_data)
    Rails.logger.info "Notificame: Updating template internally - #{template_id}"
    
    current_templates = whatsapp_channel.message_templates || []
    # Ensure current_templates is always an array (fix for existing data)
    current_templates = [] unless current_templates.is_a?(Array)
    template_index = current_templates.find_index { |t| t['id'] == template_id }
    
    return nil unless template_index
    
    # Only update internal templates (not external API ones)
    template = current_templates[template_index]
    if template['source'] != 'internal'
      Rails.logger.warn "Notificame: Cannot update external API template #{template_id}"
      return nil
    end
    
    # Update existing internal template
    current_templates[template_index].merge!(
      'name' => template_data['name'],
      'category' => template_data['category'],
      'language' => template_data['language'],
      'components' => template_data['components'],
      'updated_at' => Time.current.iso8601
    )
    
    # Templates are now stored in message_templates table, not in JSONB column
    # No need to update channel columns
    
    Rails.logger.info "Notificame: Internal template updated"
    current_templates[template_index]
  end

  def delete_template(template_name)
    Rails.logger.info "Notificame: Deleting template internally - #{template_name}"
    
    current_templates = whatsapp_channel.message_templates || []
    # Ensure current_templates is always an array (fix for existing data)
    current_templates = [] unless current_templates.is_a?(Array)
    template_index = current_templates.find_index { |t| t['name'] == template_name }
    
    return false unless template_index
    
    # Only delete internal templates (not external API ones)
    template = current_templates[template_index]
    if template['source'] != 'internal'
      Rails.logger.warn "Notificame: Cannot delete external API template #{template_name}"
      return false
    end
    
    # Remove internal template from array
    deleted_template = current_templates.delete_at(template_index)
    
    # Templates are now stored in message_templates table, not in JSONB column
    # No need to update channel columns
    
    Rails.logger.info "Notificame: Internal template deleted"
    true
  end

  def subscribe_to_webhooks
    return if whatsapp_channel.inbox.blank?

    body = {
      criteria: { channel: channel_id },
      webhook: {
        url: callback_url
      }
    }

    HTTParty.post(
      "#{BASE_URL}/subscriptions",
      headers: api_headers,
      body: body.to_json
    )
    sync_templates
  rescue StandardError => e
    Rails.logger.error "Notificame webhook subscribe error: #{e.message}"
    nil
  end

  def unsubscribe_from_webhooks
    body = {
      criteria: { channel: channel_id },
      webhook: { url: '' }
    }

    HTTParty.post(
      "#{BASE_URL}/subscriptions",
      headers: api_headers,
      body: body.to_json
    )
  rescue StandardError => e
    Rails.logger.error "Notificame webhook unsubscribe error: #{e.message}"
    nil
  end

  def validate_provider_config?
    response = HTTParty.get(
      "#{BASE_URL}/resale/",
      headers: api_headers
    )
    response.success?
  rescue StandardError
    false
  end

  def api_headers
    {
      'X-Api-Token' => whatsapp_channel.provider_config['api_token'],
      'Content-Type' => 'application/json'
    }
  end

  def download_media(file_url, mime_type)
    headers = api_headers.merge('Accept' => 'application/octet-stream')
    body = {
      from: channel_id,
      to: 'whatsapp',
      contents: [
        {
          type: 'file',
          fileUrl: file_url,
          fileMimeType: mime_type
        }
      ]
    }
    HTTParty.post(
      "#{BASE_URL}/channels/whatsapp/media",
      headers: headers,
      body: body.to_json
    )
  rescue StandardError => e
    Rails.logger.error "Notificame media download error: #{e.message}"
    nil
  end

  def media_url(_media_id)
    nil
  end

  def error_message(response)
    parsed = response.parsed_response
    return response.body.presence || 'Failed to send' unless parsed.is_a?(Hash)

    parsed.dig('messageStatus', 'error', 'message') ||
      parsed.dig('messageStatus', 'message') ||
      parsed.dig('messageStatus', 'description') ||
      parsed.dig('data', 'messageStatus', 'error', 'message') ||
      parsed.dig('data', 'messageStatus', 'message') ||
      parsed.dig('data', 'messageStatus', 'description') ||
      parsed.dig('error', 'message') ||
      parsed.dig('error', 'details') ||
      'Failed to send'
  end

  def process_response(response)
    parsed_response = response.parsed_response
    status_code = parsed_response.dig('messageStatus', 'code') ||
                  parsed_response.dig('data', 'messageStatus', 'code') ||
                  parsed_response.dig(0, 'messageStatus', 'code')

    has_error = !response.success? ||
                status_code.to_s.upcase == 'ERROR' ||
                parsed_response.dig('messageStatus', 'error').present? ||
                parsed_response.dig('data', 'messageStatus', 'error').present? ||
                parsed_response.dig(0, 'messageStatus', 'error').present? ||
                parsed_response['error'].present?

    if response.success? && parsed_response['error'].blank? && !has_error
      store_message_ids(parsed_response)
      # CRM-358: `|| true` — a success shape whose id only store_message_ids
      # understands (providerMessageId digs) must still read as success, or the
      # caller marks a delivered message as failed.
      parsed_response['messageId'] || parsed_response['id'] ||
        parsed_response.dig('data', 'id') ||
        parsed_response.dig('data', 'messageId') ||
        parsed_response.dig('data', 'messageStatus', 'messageId') ||
        parsed_response.dig('data', 0, 'messageId') ||
        parsed_response.dig('data', 0, 'id') ||
        parsed_response.dig(0, 'messageId') ||
        parsed_response.dig(0, 'id') || true
    else
      handle_error(response)
      nil
    end
  end

  def handle_error(response)
    parsed = response.parsed_response
    store_message_ids(parsed)
    super
  end

  def store_message_ids(parsed_response)
    return unless @message

    parsed = if parsed_response.is_a?(Array)
               parsed_response.first || {}
             else
               parsed_response.to_h
             end

    provider_id = parsed['providerMessageId'] ||
                  parsed.dig('data', 'providerMessageId') ||
                  parsed.dig('data', 'messageStatus', 'providerMessageId') ||
                  parsed.dig('data', 0, 'providerMessageId') ||
                  parsed.dig('messageStatus', 'providerMessageId') ||
                  parsed.dig(0, 'providerMessageId')
    provider_id = provider_id.to_s.strip
    decoded_id = decode_nested_base64(provider_id)

    message_id = parsed['messageId'] || parsed['id'] ||
                 parsed.dig('data', 'id') ||
                 parsed.dig('data', 'messageId') ||
                 parsed.dig('data', 'messageStatus', 'messageId') ||
                 parsed.dig('data', 0, 'messageId') ||
                 parsed.dig('data', 0, 'id') ||
                 parsed.dig(0, 'messageId') ||
                 parsed.dig(0, 'id')
    message_id = message_id.to_s.strip

    updates = {}
    final_provider_id = provider_id
    final_provider_id = decoded_id if final_provider_id.blank? && decoded_id.present?

    external_ids = @message.external_source_ids || {}
    external_ids['notificame'] ||= message_id if message_id.present?
    external_ids['notificame_provider_id'] ||= final_provider_id if final_provider_id.present?
    updates[:external_source_ids] = external_ids if external_ids != @message.external_source_ids

    if final_provider_id.present?
      updates[:source_id] = final_provider_id
    elsif message_id.present?
      updates[:source_id] = message_id if @message.source_id.blank?
    end
    @message.update_columns(updates) if updates.any?
  end

  private

  def fetch_templates
    response = HTTParty.get(
      "#{BASE_URL}/templates/#{channel_id}",
      headers: api_headers
    )
    return response.parsed_response['data'] if response.success?

    []
  rescue StandardError => e
    Rails.logger.error "Notificame templates fetch error: #{e.message}"
    []
  end

  def callback_url
    frontend_url = ENV.fetch('FRONTEND_URL', nil)
    "#{frontend_url}/webhooks/whatsapp/#{whatsapp_channel.phone_number}"
  end

  def channel_id
    whatsapp_channel.provider_config['channel_id']
  end

  def build_payload(phone_number, message)
    if message.attachments.present?
      attachment = message.attachments.first
      type = attachment.file_type == 'file' ? 'document' : attachment.file_type
      file_content = {
        type: 'file',
        fileMimeType: type,
        fileUrl: attachment.file_url,
        fileName: attachment.file.filename.to_s
      }
      caption = html_to_whatsapp(message.outgoing_content.to_s)
      file_content[:fileCaption] = caption if caption.present?

      {
        from: channel_id,
        to: phone_number,
        contents: [file_content]
      }
    else
      {
        from: channel_id,
        to: phone_number,
        contents: [
          {
            type: 'text',
            text: html_to_whatsapp(message.outgoing_content.to_s)
          }
        ]
      }
    end
  end

  def notificame_reply_context(message, phone_number)
    return {} unless message

    reply_msg_id = message.content_attributes[:in_reply_to]
    reply_to = message.content_attributes[:in_reply_to_external_id]
    if reply_msg_id.present?
      msg = Message.find_by(id: reply_msg_id)
      provider_reply = msg&.external_source_ids&.[]('notificame_provider_id')
      reply_to = provider_reply if provider_reply.present?
    end

    if reply_to.present?
      decoded = decode_nested_base64(reply_to)
      ids = [reply_to]
      ids << decoded if decoded.present?
      ids.each do |cid|
        msg = Message.where("external_source_ids ->> 'notificame_provider_id' = ?", cid)
                     .first
        if msg
          reply_to = msg.external_source_ids['notificame_provider_id']
          break
        end
      end
    end

    return {} if reply_to.blank?

    {
      messageId: reply_to,
      reply: true,
      to: phone_number
    }
  end

  def decode_nested_base64(str)
    return nil if str.blank?

    decoded = str.to_s
    2.times do
      temp = Base64.decode64(decoded)
      break if temp.blank? || temp == decoded

      decoded = temp
    rescue StandardError
      break
    end
    decoded.force_encoding('UTF-8')
    decoded.valid_encoding? ? decoded : nil
  end
end
