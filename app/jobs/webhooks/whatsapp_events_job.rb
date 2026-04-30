class Webhooks::WhatsappEventsJob < ApplicationJob
  queue_as :low

  def perform(params = {})
    Rails.logger.info "WhatsApp webhook processing started: #{params.inspect}"

    channel = find_channel(params)
    if channel_is_inactive?(channel)
      Rails.logger.warn("Inactive WhatsApp channel: #{channel&.phone_number || "unknown - #{params[:phone_number]}"}")
      return
    end

    Rails.logger.info "Found WhatsApp channel: #{channel.phone_number} (provider: #{channel.provider})"

    # Handle different webhook event types
    if sync_event?(params)
      handle_sync_events(channel, params)
    else
      handle_message_events(channel, params)
    end
  end

  private

  def sync_event?(params)
    # WhatsApp Cloud sync events
    whatsapp_cloud_field = params.dig(:entry, 0, :changes, 0, :field)
    whatsapp_cloud_sync_fields = %w[smb_app_state_sync smb_message_echoes history account_update user_id_update]

    # Evolution API sync events
    evolution_event = params[:event]
    evolution_sync_events = %w[contacts.upsert messages.set]

    is_whatsapp_cloud_sync = whatsapp_cloud_sync_fields.include?(whatsapp_cloud_field)
    is_evolution_sync = evolution_sync_events.include?(evolution_event)

    is_sync = is_whatsapp_cloud_sync || is_evolution_sync

    Rails.logger.info "Sync event detection: whatsapp_field=#{whatsapp_cloud_field}, evolution_event=#{evolution_event}, is_sync=#{is_sync}"
    is_sync
  end

  def handle_sync_events(channel, params)
    case channel.provider
    when 'whatsapp_cloud'
      handle_whatsapp_cloud_sync_events(channel, params)
    when 'evolution'
      handle_evolution_sync_events(channel, params)
    else
      Rails.logger.warn "Unknown provider for sync events: #{channel.provider}"
    end
  end

  def handle_whatsapp_cloud_sync_events(channel, params)
    field = params.dig(:entry, 0, :changes, 0, :field)
    Rails.logger.info "Processing WhatsApp Cloud sync event: #{field} for channel #{channel.phone_number}"

    case field
    when 'smb_app_state_sync'
      if defined?(Whatsapp::ContactSyncService)
        Whatsapp::ContactSyncService.new(inbox: channel.inbox, params: params).perform
      else
        Rails.logger.warn 'ContactSyncService not available, skipping contact sync'
      end
    when 'smb_message_echoes', 'history'
      if defined?(Whatsapp::ConversationSyncService)
        Whatsapp::ConversationSyncService.new(inbox: channel.inbox, params: params).perform
      else
        Rails.logger.warn 'ConversationSyncService not available, skipping conversation sync'
      end
    when 'account_update'
      handle_account_update(channel, params)
    when 'user_id_update'
      handle_user_id_update(channel, params)
    else
      Rails.logger.warn "Unknown WhatsApp Cloud sync event field: #{field}"
    end
  end

  def handle_account_update(channel, params)
    update_data = params.dig(:entry, 0, :changes, 0, :value)
    phone_number = update_data[:phone_number]
    event = update_data[:event]

    Rails.logger.info "[WHATSAPP] Account update event: #{event} for phone #{phone_number}"

    case event
    when 'PARTNER_REMOVED'
      Rails.logger.warn "[WHATSAPP] Partner removed from WhatsApp Business Account for #{phone_number}"
      # Mark channel as requiring reauthorization
      channel.authorization_error! if channel.respond_to?(:authorization_error!)
    when 'PHONE_NUMBER_CHANGED'
      Rails.logger.warn "[WHATSAPP] Phone number changed for account (old: #{channel.phone_number}, new: #{phone_number})"
      # Could update the channel phone number, but this requires careful consideration
    when 'ACCOUNT_STATUS_CHANGED'
      Rails.logger.info "[WHATSAPP] Account status changed for #{phone_number}"
    else
      Rails.logger.warn "[WHATSAPP] Unknown account update event: #{event}"
    end
  end

  def handle_user_id_update(channel, params)
    value = params.dig(:entry, 0, :changes, 0, :value)
    updates = value[:user_id_update]
    return unless updates.is_a?(Array)

    updates.each do |update|
      previous_bsuid = update.dig(:user_id, :previous)
      current_bsuid = update.dig(:user_id, :current)
      wa_id = update[:wa_id]

      next if previous_bsuid.blank? || current_bsuid.blank?

      Rails.logger.info "[WHATSAPP] user_id_update: #{previous_bsuid} -> #{current_bsuid} (wa_id: #{wa_id})"

      contact_inbox = channel.inbox.contact_inboxes.find_by(bsuid: previous_bsuid)
      if contact_inbox
        attrs = { bsuid: current_bsuid }
        # If source_id was set to the old BSUID (BSUID-only contact), update it too
        attrs[:source_id] = current_bsuid if contact_inbox.source_id == previous_bsuid
        contact_inbox.update!(attrs)
        Rails.logger.info "[WHATSAPP] Updated BSUID for ContactInbox #{contact_inbox.id}"
      else
        Rails.logger.warn "[WHATSAPP] No ContactInbox found with BSUID #{previous_bsuid} for user_id_update"
      end
    rescue StandardError => e
      Rails.logger.error "[WHATSAPP] user_id_update failed for #{previous_bsuid}: #{e.message}"
    end
  end

  def handle_evolution_sync_events(channel, params)
    event = params[:event]
    Rails.logger.info "Processing Evolution sync event: #{event} for channel #{channel.phone_number}"

    case event
    when 'contacts.upsert'
      handle_evolution_contacts_sync(channel, params)
    when 'messages.set'
      handle_evolution_messages_sync(channel, params)
    else
      Rails.logger.warn "Unknown Evolution sync event: #{event}"
    end
  end

  def handle_evolution_contacts_sync(channel, params)
    contacts_data = params[:data]
    return unless contacts_data.is_a?(Array)

    Rails.logger.info "[EVOLUTION] Processing #{contacts_data.size} contacts from sync webhook"

    contacts_data.each do |contact_data|
      process_evolution_contact(channel, contact_data)
    end
  end

  def process_evolution_contact(channel, contact_data)
    remote_jid = contact_data['remoteJid']
    return unless remote_jid&.include?('@s.whatsapp.net') # Only individual contacts

    phone_number = remote_jid.split('@').first
    formatted_phone = phone_number.start_with?('+') ? phone_number : "+#{phone_number}"
    push_name = contact_data['pushName']

    # Create or update contact in Evolution
    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: phone_number,
      inbox: channel.inbox,
      contact_attributes: {
        name: push_name || formatted_phone,
        phone_number: formatted_phone,
        additional_attributes: {
          evolution_contact_synced: true,
          evolution_sync_timestamp: Time.current.to_i,
          evolution_profile_pic_url: contact_data['profilePicUrl'],
          evolution_instance_id: contact_data['instanceId']
        }
      }
    ).perform

    schedule_evolution_avatar_fetch(channel, contact_inbox, phone_number)

    Rails.logger.info "[EVOLUTION] Contact synced via webhook: #{push_name} (#{formatted_phone})"
  rescue StandardError => e
    Rails.logger.error "[EVOLUTION] Contact sync failed for #{remote_jid}: #{e.message}"
  end

  # The bulk sync payload (`contacts.upsert`) often arrives without a
  # `profilePicUrl`, so we always trigger an active fetch through Evolution
  # API. Jitter prevents 50k-contact reconnects from spiking the :low queue;
  # the guard dedupes against the messages.upsert / contacts.update paths.
  def schedule_evolution_avatar_fetch(channel, contact_inbox, phone_number)
    return unless channel && contact_inbox && phone_number.present?

    contact = contact_inbox.contact
    return unless contact
    return if contact.avatar.attached?

    Whatsapp::EvolutionHandlers::AvatarEnqueueGuard.enqueue_avatar_fetch(
      contact_id: contact.id,
      phone_number: phone_number,
      channel_id: channel.id,
      jitter: true
    )
  end

  def handle_evolution_messages_sync(channel, params)
    messages_data = params[:data]
    return unless messages_data.is_a?(Array)

    Rails.logger.info "[EVOLUTION] Processing #{messages_data.size} messages from sync webhook"

    # Group messages by conversation (remoteJid)
    messages_by_chat = messages_data.group_by { |msg| msg.dig('key', 'remoteJid') }

    messages_by_chat.each do |remote_jid, chat_messages|
      process_evolution_conversation_sync(channel, remote_jid, chat_messages)
    end
  end

  def process_evolution_conversation_sync(channel, remote_jid, messages)
    return unless remote_jid&.include?('@s.whatsapp.net') # Only individual chats for now

    phone_number = remote_jid.split('@').first

    # Find or create contact
    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: phone_number,
      inbox: channel.inbox,
      contact_attributes: {
        name: phone_number,
        phone_number: "+#{phone_number}"
      }
    ).perform

    schedule_evolution_avatar_fetch(channel, contact_inbox, phone_number)

    # Find or create conversation
    conversation = contact_inbox.conversations.find_or_create_by!(
      inbox_id: channel.inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id
    )

    # Process messages for this conversation
    messages.each do |message_data|
      process_evolution_sync_message(channel, conversation, message_data)
    end

    Rails.logger.info "[EVOLUTION] Conversation sync processed: #{conversation.id} with #{messages.size} messages"
  rescue StandardError => e
    Rails.logger.error "[EVOLUTION] Conversation sync failed for #{remote_jid}: #{e.message}"
  end

  def process_evolution_sync_message(channel, conversation, message_data)
    message_id = message_data.dig('key', 'id')
    return if conversation.messages.find_by(source_id: message_id) # Skip if already exists

    # Determine message direction
    from_me = message_data.dig('key', 'fromMe') == true

    # Extract message content
    content = extract_evolution_sync_message_content(message_data)
    return if content.blank?

    # Convert messageTimestamp to proper datetime
    message_timestamp = message_data['messageTimestamp']
    created_at = message_timestamp.present? ? Time.zone.at(message_timestamp) : Time.current

    # Create message in Evolution with original timestamp
    message = conversation.messages.create!(
      content: content,
      inbox_id: channel.inbox.id,
      source_id: message_id,
      sender: from_me ? User.where(type: 'SuperAdmin').first || User.first : conversation.contact,
      sender_type: from_me ? 'User' : 'Contact',
      message_type: from_me ? :outgoing : :incoming,
      created_at: created_at,  # 🎯 Data real da mensagem!
      updated_at: created_at,  # Manter consistência
      content_attributes: {
        external_created_at: message_timestamp,
        evolution_synced: true,
        evolution_message_type: message_data['messageType'],
        evolution_status: message_data['status']
      }
    )

    Rails.logger.info "[EVOLUTION] Sync message created: #{message.id} - #{content.truncate(50)}"
  rescue StandardError => e
    Rails.logger.error "[EVOLUTION] Sync message failed for #{message_id}: #{e.message}"
  end

  def extract_evolution_sync_message_content(message_data)
    message = message_data['message']
    return unless message

    # Extract text content based on message type
    content = message['conversation'] ||
              message.dig('extendedTextMessage', 'text') ||
              message.dig('imageMessage', 'caption') ||
              message.dig('videoMessage', 'caption') ||
              message.dig('documentMessage', 'caption')

    # Fallback for media messages without caption
    content || determine_media_content(message_data['messageType'])
  end

  def determine_media_content(message_type)
    case message_type
    when 'imageMessage'
      'Image message'
    when 'audioMessage'
      'Audio message'
    when 'videoMessage'
      'Video message'
    when 'documentMessage'
      'Document message'
    when 'stickerMessage'
      'Sticker message'
    else
      'Media message'
    end
  end

  def handle_message_events(channel, params)
    Rails.logger.info "Processing message event for channel #{channel.phone_number} (provider: #{channel.provider})"

    case channel.provider
    when 'whatsapp_cloud'
      Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: params).perform
    when 'baileys'
      Whatsapp::IncomingMessageBaileysService.new(inbox: channel.inbox, params: params).perform
    when 'evolution'
      Whatsapp::IncomingMessageEvolutionService.new(inbox: channel.inbox, params: params).perform
    when 'evolution_go'
      Whatsapp::IncomingMessageEvolutionGoService.new(inbox: channel.inbox, params: params).perform
    when 'notificame'
      Whatsapp::IncomingMessageNotificameService.new(inbox: channel.inbox, params: params).perform
    when 'zapi'
      Whatsapp::IncomingMessageZapiService.new(inbox: channel.inbox, params: params).perform
    else
      Whatsapp::IncomingMessageService.new(inbox: channel.inbox, params: params).perform
    end
  end

  def find_channel(params)
    # Log detailed params for debugging
    Rails.logger.info "WhatsApp webhook channel search started with params: #{params.slice(:event, :instance, :phone_number, :server_url, :object)}"

    channel = try_find_channel_from_business_payload(params) ||
              try_find_channel_by_phone_number_id(params) ||
              try_find_channel_by_phone_number(params)

    log_channel_search_result(channel, params)
    channel
  end

  def try_find_channel_from_business_payload(params)
    return nil unless params[:object] == 'whatsapp_business_account'

    channel = find_channel_from_whatsapp_business_payload(params)
    Rails.logger.info "Channel search via Business payload: #{channel ? "found #{channel.phone_number}" : 'not found'}"
    channel
  end

  def try_find_channel_by_phone_number_id(params)
    phone_number_id = extract_phone_number_id_from_params(params)
    return nil if phone_number_id.blank?

    channel = find_channel_by_phone_number_id(phone_number_id)
    Rails.logger.info "Channel search via extracted phone_number_id #{phone_number_id}: #{channel ? "found #{channel.phone_number}" : 'not found'}"
    channel
  end

  def try_find_channel_by_phone_number(params)
    # For Z-API, find by instanceId
    if params[:instanceId].present? && params[:type].present?
      channel = find_channel_by_zapi_instance(params[:instanceId])
      if channel
        Rails.logger.info "Channel search via Z-API instanceId #{params[:instanceId]}: found #{channel.phone_number}"
        return channel
      end
    end

    # For Evolution Go, prioritize finding by instanceId
    if params[:instanceId].present?
      channel = find_channel_by_evolution_go_instance(params[:instanceId])
      if channel
        Rails.logger.info "Channel search via Evolution Go instanceId #{params[:instanceId]}: found #{channel.phone_number}"
        return channel
      end
    end

    # For Evolution API, prioritize finding by instance name + server_url
    if params[:instance].present? && params[:event].present?
      channel = find_channel_by_evolution_instance(params[:instance], params[:server_url])
      if channel
        Rails.logger.info "Channel search via Evolution instance #{params[:instance]}: found #{channel.phone_number}"
        return channel
      end
    end

    # Try phone_number parameter for other providers
    if params[:phone_number].present?
      channel = find_channel_by_phone_number(params[:phone_number])
      if channel
        Rails.logger.info "Channel search via phone_number #{params[:phone_number]}: found #{channel.phone_number}"
        return channel
      end
    end

    Rails.logger.info "Channel search: no channel found for params #{params.slice(:phone_number, :instance, :event, :instanceId)}"
    nil
  end

  def find_channel_by_phone_number_id(phone_number_id)
    channels = Channel::Whatsapp.joins(:inbox)
                                .where(provider: 'whatsapp_cloud')
                                .where("provider_config ->> 'phone_number_id' = ?", phone_number_id.to_s)

    Rails.logger.info "Found #{channels.count} whatsapp_cloud channels with phone_number_id: #{phone_number_id}"

    if channels.count > 1
      Rails.logger.warn "Multiple channels found for phone_number_id #{phone_number_id}: #{channels.map(&:phone_number).join(', ')}"
    end

    channels.first
  end

  def find_channel_by_evolution_instance(instance_name, server_url = nil)
    # Try to find by both instance_name and server_url for better precision
    if server_url.present?
      channel = Channel::Whatsapp.joins(:inbox)
                                 .where(provider: 'evolution')
                                 .where("provider_config ->> 'instance_name' = ?", instance_name)
                                 .where("provider_config ->> 'api_url' = ?", server_url)
                                 .first

      Rails.logger.info "Evolution channel search: instance=#{instance_name}, server_url=#{server_url} - #{channel ? 'found' : 'not found'}"
      return channel if channel
    end

    # Fallback to instance_name only if server_url matching fails
    channel = Channel::Whatsapp.joins(:inbox)
                               .where(provider: 'evolution')
                               .where("provider_config ->> 'instance_name' = ?", instance_name)
                               .first

    Rails.logger.info "Evolution channel search (fallback): instance=#{instance_name} only - #{channel ? 'found' : 'not found'}"
    channel
  end

  def find_channel_by_zapi_instance(instance_id)
    Rails.logger.info "Z-API channel search: Searching for instance_id=#{instance_id}"

    channel = Channel::Whatsapp.joins(:inbox)
                               .where(provider: 'zapi')
                               .where("provider_config ->> 'instance_id' = ?", instance_id)
                               .first

    Rails.logger.info "Z-API channel search: instance_id=#{instance_id} - #{channel ? "found channel #{channel.id}" : 'not found'}"
    channel
  end

  def find_channel_by_evolution_go_instance(instance_uuid)
    Rails.logger.info "Evolution Go channel search: Searching for instance_uuid=#{instance_uuid}"

    # List all Evolution Go channels for debugging
    all_evolution_go_channels = Channel::Whatsapp.joins(:inbox)
                                                 .where(provider: 'evolution_go')

    Rails.logger.info "Evolution Go channel search: Found #{all_evolution_go_channels.count} evolution_go channels total"

    all_evolution_go_channels.each do |channel|
      config_instance_uuid = channel.provider_config['instance_uuid']
      Rails.logger.info "Evolution Go channel search: Channel #{channel.id} has instance_uuid: #{config_instance_uuid}"
    end

    channel = Channel::Whatsapp.joins(:inbox)
                               .where(provider: 'evolution_go')
                               .where("provider_config ->> 'instance_uuid' = ?", instance_uuid)
                               .first

    Rails.logger.info "Evolution Go channel search: instance_uuid=#{instance_uuid} - #{channel ? "found channel #{channel.id}" : 'not found'}"
    channel
  end

  def find_channel_by_phone_number(phone_number)
    Channel::Whatsapp.find_by(phone_number: phone_number)
  end

  def log_channel_search_result(channel, params)
    if channel
      Rails.logger.info "✅ Channel found: #{channel.phone_number} (provider: #{channel.provider}, inbox: #{channel.inbox.name})"
    else
      Rails.logger.warn "❌ No channel found for webhook params: #{params.slice(:event, :instance, :phone_number, :server_url, :object)}"

      # Additional debugging for Evolution API
      if params[:instance].present?
        evolution_channels = Channel::Whatsapp.where(provider: %w[evolution evolution_go])
        Rails.logger.warn "Available Evolution channels: #{evolution_channels.map do |c|
          "#{c.phone_number} (instance: #{c.provider_config['instance_name']}, api_url: #{c.provider_config['api_url']})"
        end}"
      end
    end
  end

  def channel_is_inactive?(channel)
    return true if channel.blank?
    return true if channel.reauthorization_required?

    false
  end

  def find_channel_from_whatsapp_business_payload(params)
    phone_number, phone_number_id = extract_business_payload_metadata(params)

    Rails.logger.info "Business payload metadata: phone_number=#{phone_number}, phone_number_id=#{phone_number_id}"

    # For WhatsApp Cloud, prioritize phone_number_id lookup as it's unique per business account
    if phone_number_id.present?
      channel = find_channel_by_phone_number_id(phone_number_id)
      if channel
        Rails.logger.info "Channel found by phone_number_id: #{channel.phone_number} (phone_number_id: #{phone_number_id})"
        return channel
      end
    end

    # Fallback: try to find by phone_number and validate phone_number_id
    if phone_number.present?
      channel = find_and_validate_channel_by_phone(phone_number, phone_number_id)
      if channel
        Rails.logger.info "Channel found by phone_number validation: #{channel.phone_number}"
        return channel
      end
    end

    Rails.logger.warn "No channel found for business payload: phone_number=#{phone_number}, phone_number_id=#{phone_number_id}"
    nil
  end

  def extract_business_payload_metadata(params)
    metadata = params[:entry]&.first&.dig(:changes)&.first&.dig(:value, :metadata)
    return [nil, nil] unless metadata

    phone_number = "+#{metadata[:display_phone_number]}"
    phone_number_id = metadata[:phone_number_id]

    [phone_number, phone_number_id]
  end

  def find_and_validate_channel_by_phone(phone_number, phone_number_id)
    channel = Channel::Whatsapp.find_by(phone_number: phone_number)

    if channel&.provider_config&.dig('phone_number_id') == phone_number_id
      Rails.logger.info 'Channel matched by phone_number and phone_number_id validation'
      return channel
    end

    nil
  end

  def extract_phone_number_id_from_params(params)
    phone_number_id = extract_from_entry_changes(params) ||
                      extract_from_metadata(params) ||
                      extract_from_messages(params)

    Rails.logger.info "Extracted phone_number_id: #{phone_number_id}" if phone_number_id.present?
    phone_number_id
  end

  def extract_from_entry_changes(params)
    return nil if params[:entry].blank?

    params[:entry].first[:changes]&.first&.dig(:value, :metadata, :phone_number_id)
  end

  def extract_from_metadata(params)
    return nil if params[:metadata].blank?

    params[:metadata][:phone_number_id]
  end

  def extract_from_messages(params)
    return nil if params[:messages].blank?

    params[:messages].first&.dig(:metadata, :phone_number_id)
  end
end
