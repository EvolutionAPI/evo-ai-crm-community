module Whatsapp::EvolutionHandlers::ContentHandlers
  def handle_location
    location_msg = @raw_message.dig(:message, :locationMessage)
    return unless location_msg

    @message.content_attributes[:location] = {
      latitude: location_msg[:degreesLatitude],
      longitude: location_msg[:degreesLongitude],
      name: location_msg[:name],
      address: location_msg[:address]
    }
  end

  def handle_contacts
    contact_msg = @raw_message.dig(:message, :contactMessage)
    contacts_array = @raw_message.dig(:message, :contactsArrayMessage, :contacts)

    contacts = if contact_msg
                 [contact_msg]
               elsif contacts_array
                 contacts_array
               else
                 []
               end

    @message.content_attributes[:contacts] = contacts.map do |contact|
      {
        display_name: contact[:displayName],
        vcard: contact[:vcard]
      }
    end
  end

  def message_content_attributes
    content_attributes = {
      external_created_at: evolution_extract_message_timestamp(@raw_message[:messageTimestamp])
    }

    if message_type == 'reaction'
      content_attributes[:in_reply_to_external_id] = @raw_message.dig(:message, :reactionMessage, :key, :id)
      content_attributes[:is_reaction] = true
    elsif message_type == 'unsupported'
      content_attributes[:is_unsupported] = true
    end

    content_attributes[:sender_name] = participant_push_name if jid_type == 'group' && participant_push_name.present?
    content_attributes[:media_type] = message_type if media_attachment?

    content_attributes
  end
end
