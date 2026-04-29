class Whatsapp::SendOnWhatsappService < Base::SendOnChannelService
  include BaileysHelper

  private

  def channel_class
    Channel::Whatsapp
  end

  def perform_reply
    should_send_template_message = template_params.present? || !message.conversation.can_reply?
    if should_send_template_message
      send_template_message
    elsif channel.provider == 'baileys'
      send_baileys_session_message
    else
      send_session_message
    end
  end

  def send_template_message
    name, namespace, lang_code, processed_parameters = processable_channel_message_template

    return if name.blank?

    # Use contact identifier if available (for Evolution Go SenderAlt), otherwise fallback to source_id
    target_number = determine_target_number_for_sending

    Rails.logger.info "WhatsApp Template: Using number #{target_number} for contact #{message.conversation.contact.id}"

    message_id = channel.send_template(target_number, {
                                         name: name,
                                         namespace: namespace,
                                         lang_code: lang_code,
                                         parameters: processed_parameters
                                       })
    message.update!(source_id: message_id) if message_id.present?
  end

  def processable_channel_message_template
    if template_params.present?
      return [
        template_params['name'],
        template_params['namespace'],
        template_params['language'],
        processed_templates_params(template_params)
      ]
    end

    # Delete the following logic once the update for template_params is stable
    # see if we can match the message content to a template
    # An example template may look like "Your package has been shipped. It will be delivered in {{1}} business days.
    # We want to iterate over these templates with our message body and see if we can fit it to any of the templates
    # Then we use regex to parse the template varibles and convert them into the proper payload
    channel.message_templates&.each do |template|
      match_obj = template_match_object(template)
      next if match_obj.blank?

      # we have a match, now we need to parse the template variables and convert them into the wa recommended format
      processed_parameters = match_obj.captures.map { |x| { type: 'text', text: x } }

      # no need to look up further end the search
      return [template['name'], template['namespace'], template['language'], processed_parameters]
    end
    [nil, nil, nil, nil]
  end

  def template_match_object(template)
    body_object = validated_body_object(template)
    return if body_object.blank?

    template_match_regex = build_template_match_regex(body_object['text'])
    message.content.match(template_match_regex)
  end

  def build_template_match_regex(template_text)
    # Converts the whatsapp template to a comparable regex string to check against the message content
    # the variables are of the format {{num}} ex:{{1}}

    # transform the template text into a regex string
    # we need to replace the {{num}} with matchers that can be used to capture the variables
    template_text = template_text.gsub(/{{\d}}/, '(.*)')
    # escape if there are regex characters in the template text
    template_text = Regexp.escape(template_text)
    # ensuring only the variables remain as capture groups
    template_text = template_text.gsub(Regexp.escape('(.*)'), '(.*)')

    template_match_string = "^#{template_text}$"
    Regexp.new template_match_string
  end

  def template(template_params)
    channel.message_templates.find do |t|
      t['name'] == template_params['name'] && t['language'] == template_params['language']
    end
  end

  def processed_templates_params(template_params)
    template = template(template_params)
    return if template.blank?

    parameter_format = template['parameter_format']

    if parameter_format == 'NAMED'
      template_params['processed_params']&.map { |key, value| { type: 'text', parameter_name: key, text: value } }
    else
      template_params['processed_params']&.map { |_, value| { type: 'text', text: value } }
    end
  end

  def validated_body_object(template)
    # we don't care if its not approved template
    return if template['status'] != 'approved'

    # we only care about text body object in template. if not present we discard the template
    # we don't support other forms of templates
    template['components'].find { |obj| obj['type'] == 'BODY' && obj.key?('text') }
  end

  def send_baileys_session_message
    with_baileys_channel_lock_on_outgoing_message(channel.id) { send_session_message }
  end

  def send_session_message
    # Use contact identifier if available (for Evolution Go SenderAlt), otherwise fallback to source_id
    target_number = determine_target_number_for_sending

    Rails.logger.info "WhatsApp Send: Using number #{target_number} for contact #{message.conversation.contact.id} (identifier: #{message.conversation.contact.identifier}, source_id: #{message.conversation.contact_inbox.source_id})"

    message_id = channel.send_message(target_number, message)
    message.update!(source_id: message_id) if message_id.present?
  end

  def determine_target_number_for_sending
    contact = message.conversation.contact
    contact_inbox = message.conversation.contact_inbox

    Rails.logger.info "WhatsApp Send: Determining target number for contact #{contact.id} (identifier: #{contact.identifier}, phone: #{contact.phone_number}, source_id: #{contact_inbox.source_id})"

    # WhatsApp group conversations (Evolution API + Evolution Go): the recipient is the
    # group JID (`@g.us`), not the contact's phone or identifier.
    return group_jid_from_conversation if route_to_group?

    # For Z-API provider: use phone without +, or identifier as fallback
    if channel.provider == 'zapi'
      # If contact has phone_number, use it without +
      if contact.phone_number.present?
        target = contact.phone_number.delete('+')
        Rails.logger.info "WhatsApp Send: Using phone_number #{target} (from #{contact.phone_number}) - Z-API format"
        return target
      # If contact has identifier, use it
      elsif contact.identifier.present?
        Rails.logger.info "WhatsApp Send: Using identifier #{contact.identifier} - Z-API fallback"
        return contact.identifier
      # If contact_inbox source_id is an identifier (e.g., 96426461769841@lid), use it
      elsif contact_inbox.source_id.present?
        Rails.logger.info "WhatsApp Send: Using source_id #{contact_inbox.source_id} - Z-API fallback"
        return contact_inbox.source_id
      end
    # For Evolution Go provider, identifier prioritizes over phone_number
    elsif channel.provider == 'evolution_go'
      # If contact has identifier, use it (covers new and updated contacts)
      if contact.identifier.present?
        Rails.logger.info "WhatsApp Send: Using identifier #{contact.identifier}"
        contact.identifier
      # If contact_inbox source_id is an identifier (e.g., 96426461769841@lid), use it
      elsif contact_inbox.source_id.include?('@lid')
        Rails.logger.info "WhatsApp Send: Using source_id identifier #{contact_inbox.source_id}"
        contact_inbox.source_id
      # Fallback to contact's phone number if available
      elsif contact.phone_number.present?
        target = contact.phone_number.delete('+')
        Rails.logger.info "WhatsApp Send: Using phone_number #{target} (from #{contact.phone_number}) - clean number without @lid"
        target
      else
        # Last resort, use contact_inbox.source_id (might be a phone number)
        Rails.logger.info "WhatsApp Send: Using source_id fallback #{contact_inbox.source_id}"
        contact_inbox.source_id
      end
    else
      # Default behavior for whatsapp_cloud and other providers
      source_id = contact_inbox.source_id
      # If source_id is a BSUID, prefer phone_number if available
      if source_id.match?(RegexHelper::BSUID_REGEX)
        if contact.phone_number.present?
          contact.phone_number.delete('+')
        else
          # BSUID-only: return BSUID, WhatsappCloudService will use `recipient` field
          source_id
        end
      else
        source_id
      end
    end
  end

  def template_params
    message.additional_attributes && message.additional_attributes['template_params']
  end

  def route_to_group?
    channel.provider.in?(%w[evolution evolution_go]) && group_jid_from_conversation.present?
  end

  def group_jid_from_conversation
    attrs = message.conversation.additional_attributes || {}
    candidate = attrs['evolution_go_chat_id'] || attrs['evolution_chat_id']
    candidate if candidate.is_a?(String) && candidate.end_with?('@g.us')
  end
end
