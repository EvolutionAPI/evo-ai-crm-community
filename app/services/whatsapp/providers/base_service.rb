#######################################
# To create a whatsapp provider
# - Inherit this as the base class.
# - Implement `send_message` method in your child class.
# - Implement `send_template_message` method in your child class.
# - Implement `sync_templates` method in your child class.
# - Implement `validate_provider_config` method in your child class.
# - Use Childclass.new(whatsapp_channel: channel).perform.
######################################

class Whatsapp::Providers::BaseService
  pattr_initialize [:whatsapp_channel!]

  def send_message(_phone_number, _message)
    raise 'Overwrite this method in child class'
  end

  def send_template(_phone_number, _template_info)
    raise 'Overwrite this method in child class'
  end

  def sync_template
    raise 'Overwrite this method in child class'
  end

  def validate_provider_config
    raise 'Overwrite this method in child class'
  end

  def error_message
    raise 'Overwrite this method in child class'
  end

  def process_response(response)
    parsed_response = response.parsed_response
    if response.success? && parsed_response['error'].blank?
      parsed_response['messages'].first['id']
    else
      handle_error(response)
      nil
    end
  end

  def handle_error(response)
    Rails.logger.error response.body
    return if @message.blank?

    # https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes/#sample-response
    error_message = error_message(response)
    return if error_message.blank?

    # EVO-1460 follow-up: route through the funnel so Wisper :message_status_changed
    # is published — handle_error used to bypass it via save! and the nil return tricked
    # send_on_whatsapp_service's `== false` guard, leaving Cloud failures invisible to
    # the EvoFlow listener (EVO-1240).
    Messages::StatusUpdateService.new(@message, 'failed', error_message).perform
  end

  def create_buttons(items)
    buttons = []
    items.each do |item|
      button = { :type => 'reply', 'reply' => { 'id' => item['value'], 'title' => item['title'] } }
      buttons << button
    end
    buttons
  end

  def create_rows(items)
    rows = []
    items.each do |item|
      row = { 'id' => item['value'], 'title' => item['title'] }
      rows << row
    end
    rows
  end

  def html_to_whatsapp(text)
    return '' if text.blank?

    result = text.dup
    result.gsub!(%r{<br\s*/?>}i, "\n")
    result.gsub!(%r{</p>\s*<p[^>]*>}i, "\n\n")
    result.gsub!(%r{<li[^>]*>}i, "- ")
    result.gsub!(%r{</li>}i, "\n")
    result.gsub!(%r{</?[uo]l[^>]*>}i, "\n")
    result.gsub!(%r{</?(p|div)[^>]*>}i, "\n")
    result.gsub!(%r{<strong[^>]*>(.*?)</strong>}im, '*\1*')
    result.gsub!(%r{<b[^>]*>(.*?)</b>}im, '*\1*')
    result.gsub!(%r{<em[^>]*>(.*?)</em>}im, '_\1_')
    result.gsub!(%r{<i[^>]*>(.*?)</i>}im, '_\1_')
    result.gsub!(%r{<code[^>]*>(.*?)</code>}im, '`\1`')
    result.gsub!(%r{<s[^>]*>(.*?)</s>}im, '~\1~')
    result.gsub!(%r{<strike[^>]*>(.*?)</strike>}im, '~\1~')
    result.gsub!(%r{<del[^>]*>(.*?)</del>}im, '~\1~')
    result = ActionController::Base.helpers.strip_tags(result)
    result.gsub!(/[ \t]+/, ' ')
    result.gsub!(/\n{3,}/, "\n\n")
    result.strip
  end

  def create_payload(type, message_content, action)
    {
      'type': type,
      'body': {
        'text': message_content
      },
      'action': action
    }
  end

  def create_payload_based_on_items(message)
    if message.content_attributes['items'].length <= 3
      create_button_payload(message)
    else
      create_list_payload(message)
    end
  end

  def interactive_body_text(message)
    content = html_to_whatsapp(message.content.to_s)
    return content if content.blank?

    lines = content.split("\n")
    removed_any = false

    while lines.any? && lines.last.strip.match?(/^\d+\.\s+\S/)
      lines.pop
      removed_any = true
    end

    pruned = lines.join("\n").strip
    return content unless removed_any
    pruned.presence || content
  end

  def create_button_payload(message)
    buttons = create_buttons(message.content_attributes['items'])
    json_hash = { 'buttons' => buttons }
    create_payload('button', interactive_body_text(message), JSON.generate(json_hash))
  end

  def create_list_payload(message)
    rows = create_rows(message.content_attributes['items'])
    section1 = { 'rows' => rows }
    sections = [section1]
    json_hash = { :button => 'Choose an item', 'sections' => sections }
    create_payload('list', interactive_body_text(message), JSON.generate(json_hash))
  end
end
