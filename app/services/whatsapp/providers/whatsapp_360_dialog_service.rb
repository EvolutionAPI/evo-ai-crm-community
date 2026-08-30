class Whatsapp::Providers::Whatsapp360DialogService < Whatsapp::Providers::BaseService
  include Whatsapp::Providers::Concerns::TemplateSync
  
  def send_message(phone_number, message)
    @message = message
    if message.attachments.present?
      send_attachment_message(phone_number, message)
    elsif message.content_type == 'input_select'
      send_interactive_text_message(phone_number, message)
    else
      send_text_message(phone_number, message)
    end
  end

  def send_template(phone_number, template_info)
    response = HTTParty.post(
      "#{api_base_path}/messages",
      headers: api_headers,
      body: {
        to: phone_number,
        template: template_body_parameters(template_info),
        type: 'template'
      }.to_json
    )

    process_response(response)
  end

  def sync_templates
    response = HTTParty.get("#{api_base_path}/configs/templates", headers: api_headers)
    return unless response.success?
    
    templates = response['waba_templates']
    return if templates.blank?

    # Sincronizar templates na nova tabela
    templates.each do |template_data|
      sync_template_to_database(template_data)
    end
  rescue StandardError => e
    Rails.logger.error "360Dialog sync_templates error: #{e.message}"
  end

  def validate_provider_config?
    response = HTTParty.post(
      "#{api_base_path}/configs/webhook",
      headers: { 'D360-API-KEY': whatsapp_channel.provider_config['api_key'], 'Content-Type': 'application/json' },
      body: {
        url: "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/whatsapp/#{whatsapp_channel.phone_number}"
      }.to_json
    )
    response.success?
  end

  def api_headers
    { 'D360-API-KEY' => whatsapp_channel.provider_config['api_key'], 'Content-Type' => 'application/json' }
  end

  def media_url(media_id)
    "#{api_base_path}/media/#{media_id}"
  end

  private

  def api_base_path
    # provide the environment variable when testing against sandbox : 'https://waba-sandbox.360dialog.io/v1'
    ENV.fetch('360DIALOG_BASE_URL', 'https://waba.360dialog.io/v1')
  end

  def send_text_message(phone_number, message)
    response = HTTParty.post(
      "#{api_base_path}/messages",
      headers: api_headers,
      body: {
        to: phone_number,
        text: { body: html_to_whatsapp(message.content) },
        type: 'text'
      }.to_json
    )

    process_response(response)
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    type = %w[image audio video].include?(attachment.file_type) ? attachment.file_type : 'document'
    type_content = {
      'link': attachment.download_url
    }
    type_content['caption'] = html_to_whatsapp(message.content.to_s) unless %w[audio sticker].include?(type)
    type_content['filename'] = attachment.file.filename if type == 'document'

    response = HTTParty.post(
      "#{api_base_path}/messages",
      headers: api_headers,
      body: {
        'to' => phone_number,
        'type' => type,
        type.to_s => type_content
      }.to_json
    )

    process_response(response)
  end

  def error_message(response)
    # {"meta": {"success": false, "http_code": 400, "developer_message": "errro-message", "360dialog_trace_id": "someid"}}
    parsed = response.parsed_response
    return response.body.to_s.truncate(300).presence unless parsed.is_a?(Hash)

    parsed.dig('meta', 'developer_message')
  end

  def template_body_parameters(template_info)
    {
      name: template_info[:name],
      namespace: template_info[:namespace],
      language: {
        policy: 'deterministic',
        code: template_info[:lang_code]
      },
      components: [{
        type: 'body',
        parameters: template_info[:parameters]
      }]
    }
  end

  def send_interactive_text_message(phone_number, message)
    payload = create_payload_based_on_items(message)

    response = HTTParty.post(
      "#{api_base_path}/messages",
      headers: api_headers,
      body: {
        to: phone_number,
        interactive: payload,
        type: 'interactive'
      }.to_json
    )

    process_response(response)
  end
end
