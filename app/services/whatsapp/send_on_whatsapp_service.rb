class Whatsapp::SendOnWhatsappService < Base::SendOnChannelService
  UNSUPPORTED_CONTENT_REASON = 'Content type is not supported by this WhatsApp channel'.freeze

  private

  def channel_class
    Channel::Whatsapp
  end

  def perform_reply
    should_send_template_message = template_params.present? || !message.conversation.can_reply?
    if should_send_template_message
      send_template_message
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

    # One instance: the channel's `delegate` builds a fresh service per call,
    # which would drop `last_delivery_error`.
    provider = channel.provider_service
    message_id = provider.send_template(target_number, {
                                          name: name,
                                          namespace: namespace,
                                          lang_code: lang_code,
                                          parameters: processed_parameters
                                        })

    handle_send_result(message_id, provider, 'Template delivery failed: provider returned an error response')
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

  def send_session_message
    # Use contact identifier if available (for Evolution Go SenderAlt), otherwise fallback to source_id
    target_number = determine_target_number_for_sending

    Rails.logger.info "WhatsApp Send: Using number #{target_number} for contact #{message.conversation.contact.id} (identifier: #{message.conversation.contact.identifier}, source_id: #{message.conversation.contact_inbox.source_id})"

    provider = channel.provider_service
    message_id = provider.send_message(target_number, message)

    handle_send_result(message_id, provider, 'Delivery failed: provider returned an error response')
  end

  # Single owner of failure marking: any return that is not a known success shape
  # (id or `true`) is failed, never ignored — a nil flagged `is_unsupported` is a
  # pre-send refusal, so it never reached the API either.
  def handle_send_result(result, provider, fallback_reason)
    return if result == true
    # Every error path returns nil/false, so a blank-String id is a success
    # shape with an empty id field, not a failure.
    return if result.is_a?(String) && result.blank?

    if result.present?
      message.update!(source_id: result.to_s)
      return
    end

    reason = send_failure_reason(result, provider, fallback_reason)
    Rails.logger.error "[WhatsApp] Delivery failed for message #{message.id}: #{reason}"
    marked = Messages::StatusUpdateService.new(message, 'failed', reason).perform
    # A terminal status (already failed/read, or a race with the echo webhook)
    # refuses the transition — surface it instead of silently losing the reason.
    Rails.logger.warn "[WhatsApp] Message #{message.id} not remarked as failed (status #{message.status} is terminal)" unless marked
  end

  # Defensive ordering only: today no provider both records an error and flags
  # the message, and a concrete error would beat the generic reason.
  def send_failure_reason(result, provider, fallback_reason)
    provider_error = provider.last_delivery_error.presence
    return provider_error if provider_error
    return UNSUPPORTED_CONTENT_REASON if result.nil? && message.is_unsupported.present?

    fallback_reason
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
      # Use identifier ONLY when it looks like a valid number/JID (Evolution Go SenderAlt).
      # A non-numeric identifier (e.g. imported lead label "samambaia-090") is an external ID,
      # never a WhatsApp destination — fall back to phone_number / source_id.
      if contact.identifier.present? && valid_wa_destination?(contact.identifier)
        target = contact.identifier.delete_prefix('+')
        Rails.logger.info "WhatsApp Send: Using identifier #{target}"
        target
      # If contact_inbox source_id is an identifier (e.g., 96426461769841@lid), use it
      elsif contact_inbox.source_id&.include?('@lid')
        Rails.logger.info "WhatsApp Send: Using source_id identifier #{contact_inbox.source_id}"
        contact_inbox.source_id
      # Fallback to contact's phone number if available
      elsif contact.phone_number.present?
        target = contact.phone_number.delete('+')
        Rails.logger.info "WhatsApp Send: Using phone_number #{target} (from #{contact.phone_number}) - clean number without @lid"
        target
      else
        # Last resort. A LID chat whose contact_inbox predates the LID-preserving
        # ingest stores a bare digit string, which Evolution Go would rewrite to
        # "@s.whatsapp.net" and fail to route. The conversation still carries the
        # original "@lid" JID, so prefer it as the destination.
        target = lid_jid_from_conversation.presence || contact_inbox.source_id
        Rails.logger.info "WhatsApp Send: Using source_id fallback #{target}"
        target
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

  # A valid Evolution Go destination is a numeric JID (@lid / @s.whatsapp.net, or
  # @g.us with the optional legacy hyphen) or a digits-only string with an optional
  # leading +. Deliberately stricter than RegexHelper::WHATSAPP_CHANNEL_REGEX, which
  # validates inbound source_ids (1-digit numbers, BSUIDs) and lacks @s.whatsapp.net:
  # here a false positive sends a message to a wrong destination (EVO-1682).
  def valid_wa_destination?(value)
    value.to_s.match?(/\A\+?\d+(?:-\d+)?@(?:lid|s\.whatsapp\.net|g\.us)\z/) ||
      value.to_s.match?(/\A\+?\d{8,15}\z/)
  end

  def template_params
    message.additional_attributes && message.additional_attributes['template_params']
  end

  def route_to_group?
    channel.provider.in?(%w[evolution evolution_go]) && group_jid_from_conversation.present?
  end

  # The chat JID recorded when the conversation was created. It keeps the original
  # WhatsApp server ("@g.us", "@lid", "@s.whatsapp.net") even when the contact_inbox
  # stores a bare number, so it is the fallback source of a routable destination.
  def chat_jid_from_conversation
    attrs = message.conversation.additional_attributes || {}
    key = channel.provider == 'evolution_go' ? 'evolution_go_chat_id' : 'evolution_chat_id'
    attrs[key]
  end

  def group_jid_from_conversation
    candidate = chat_jid_from_conversation
    candidate if candidate.is_a?(String) && candidate.end_with?('@g.us')
  end

  def lid_jid_from_conversation
    candidate = chat_jid_from_conversation
    candidate if candidate.is_a?(String) && candidate.end_with?('@lid')
  end
end
