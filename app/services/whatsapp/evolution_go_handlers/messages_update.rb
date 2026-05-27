module Whatsapp::EvolutionGoHandlers::MessagesUpdate
  include Whatsapp::EvolutionGoHandlers::Helpers

  private

  def process_messages_update
    # Evolution Go API v2.3.1 sends update data directly in 'data' field
    update_data = processed_params[:data]
    return if update_data.blank?

    # Ensure updates is an array
    updates = update_data.is_a?(Array) ? update_data : [update_data]

    Rails.logger.info "Evolution Go API: Processing #{updates.size} message updates"

    updates.each do |update|
      process_single_message_update(update)
    end
  end

  def process_single_message_update(update)
    raw_message_id = update.dig(:key, :id)
    Rails.logger.info "Evolution Go API: Processing update for message #{raw_message_id}"
    Rails.logger.debug { "Evolution Go API: Update payload structure: #{update.keys}" }
    Rails.logger.debug { "Evolution Go API: fromMe: #{update[:fromMe]}, remoteJid: #{update[:remoteJid]}" }

    # Skip if no message ID
    return unless raw_message_id

    begin
      handle_single_message_update(update, raw_message_id)
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Error processing message update: #{e.message}"
      Rails.logger.error "Evolution Go API: Update data: #{update.inspect}"
    end
  end

  def handle_single_message_update(update, raw_message_id)
    # Find existing message by source_id
    message = find_message_by_source_id(raw_message_id, update)

    unless message
      Rails.logger.warn "Evolution Go API: Message not found for update: #{raw_message_id}"
      return
    end

    update_message_status(message, update, raw_message_id)
    handle_message_edit(message, update, raw_message_id) if update[:editedMessage]
  end

  def find_message_by_source_id(raw_message_id, update)
    # Try to find the message by source_id first
    message = inbox.messages.find_by(source_id: raw_message_id)

    # If not found and message is outgoing, search in all messages
    Rails.logger.warn "Evolution Go API: Outgoing message not found for update: #{raw_message_id}" if !message && update[:fromMe]

    message
  end

  def update_message_status(message, update, raw_message_id)
    # Map Evolution Go status to Evolution status
    status = map_evolution_go_status_to_evolution(update[:status])&.to_s
    return unless status

    Rails.logger.info "Evolution Go API: Updating message #{raw_message_id} status to #{status}"

    if Messages::StatusUpdateService.new(message, status).perform
      Rails.logger.debug 'Evolution Go API: Message status updated successfully'
    else
      Rails.logger.warn "Evolution Go API: Status transition not allowed: #{message.status} -> #{status}"
    end
  end

  def map_evolution_go_status_to_evolution(status)
    # Evolution Go API status mapping
    # Evolution Go statuses: PENDING, ERROR, SERVER_ACK, DELIVERY_ACK, READ, PLAYED
    case status
    when 'PENDING'
      :sent
    when 'ERROR'
      :failed
    when 'SERVER_ACK'
      :sent
    when 'DELIVERY_ACK'
      :delivered
    when 'READ'
      :read
    when 'PLAYED'
      # Evolution Go supports PLAYED status for voice messages
      Rails.logger.debug { "Evolution Go API: Message #{@message_id} was played" }
      :read
    else
      Rails.logger.warn "Evolution Go API: Unknown message status: #{status}"
      nil
    end
  end

  def handle_message_edit(message, update, raw_message_id)
    Rails.logger.info "Evolution Go API: Message #{raw_message_id} was edited"

    edited_message = update[:editedMessage]
    new_content = extract_text_from_edited_message(edited_message)

    return unless new_content

    # Update message content
    message.update!(
      content: new_content,
      additional_attributes: message.additional_attributes.merge(
        evolution_go_edited: true,
        evolution_go_edit_timestamp: edited_message[:timestampMs]
      )
    )

    Rails.logger.debug 'Evolution Go API: Message content updated successfully'
  end

  def extract_text_from_edited_message(edited_message)
    # Extract text from edited message structure
    edited_message.dig(:extendedTextMessage, :text) ||
      edited_message[:conversation] ||
      edited_message.to_s
  end
end
