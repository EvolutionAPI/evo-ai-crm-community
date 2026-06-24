module Whatsapp::EvolutionHandlers::MessagesUpdate
  include Whatsapp::EvolutionHandlers::Helpers

  class MessageNotFoundError < StandardError; end

  private

  def process_messages_update
    # Evolution API v2.3.1 sends update data directly in 'data' field
    update_data = processed_params[:data]
    return if update_data.blank?

    # Handle both single update and array of updates
    updates = update_data.is_a?(Array) ? update_data : [update_data]

    Rails.logger.info "Evolution API: Processing #{updates.size} message updates"

    updates.each do |update|
      @message = nil
      @raw_message = update

      Rails.logger.info "Evolution API: Processing update for message #{raw_message_id}"
      Rails.logger.debug { "Evolution API: Update payload structure: #{update.keys}" }
      Rails.logger.debug { "Evolution API: fromMe: #{update[:fromMe]}, remoteJid: #{update[:remoteJid]}" }

      begin
        if incoming?
          handle_update
        else
          # Handle outgoing message status updates
          handle_outgoing_update
        end
      rescue StandardError => e
        Rails.logger.error "Evolution API: Error processing message update: #{e.message}"
        Rails.logger.error "Evolution API: Update data: #{update.inspect}"
        Rails.logger.error e.backtrace.first(5).join("\n")
      end
    end
  end

  # EVO-1890: contact revokes (delete-for-everyone) arrive as a messages.delete
  # event ({ ...key, status: 'DELETED' }). Mark the original as revoked_by_contact
  # (content kept, shown with a notice) instead of letting it pass unhandled.
  def process_messages_delete
    data = processed_params[:data]
    return if data.blank?

    entries = data.is_a?(Array) ? data : [data]
    entries.each do |entry|
      source_id = entry[:id] || entry.dig(:key, :id)
      next if source_id.blank?

      Rails.logger.info "Evolution API: messages.delete for #{source_id} — marking revoked_by_contact"
      mark_message_revoked_by_source_id(source_id)
    end
  end

  def handle_update
    unless find_message_by_source_id(raw_message_id)
      Rails.logger.warn "Evolution API: Message not found for update: #{raw_message_id}"
      return
    end

    update_status if @raw_message[:status].present?
    handle_edited_content if @raw_message[:message].present?
  end

  def handle_outgoing_update
    unless find_message_by_source_id(raw_message_id)
      Rails.logger.warn "Evolution API: Outgoing message not found for update: #{raw_message_id}"
      return
    end

    update_status if @raw_message[:status].present?
  end

  def update_status
    status = status_mapper
    return if status.blank?

    Rails.logger.info "Evolution API: Updating message #{raw_message_id} status to #{status}"

    update_last_seen_at if incoming? && status == 'read'

    if Messages::StatusUpdateService.new(@message, status).perform
      refresh_conversation_activity
      Rails.logger.debug 'Evolution API: Message status updated successfully'
    else
      Rails.logger.warn "Evolution API: Status transition not allowed: #{@message.status} -> #{status}"
    end
  end

  def status_mapper
    # Evolution API status mapping
    # Evolution statuses: PENDING, ERROR, SERVER_ACK, DELIVERY_ACK, READ, PLAYED
    status = @raw_message[:status]

    case status
    when 0, 'PENDING'
      'sent'
    when 1, 'ERROR', 'FAILED'
      'failed'
    when 2, 'SERVER_ACK', 'SENT'
      'sent'
    when 3, 'DELIVERY_ACK', 'DELIVERED'
      'delivered'
    when 4, 'READ'
      'read'
    when 5, 'PLAYED'
      # Evolution supports PLAYED status for voice messages
      Rails.logger.debug { "Evolution API: Message #{raw_message_id} was played" }
      'read' # Map to read for now since Evolution doesn't have 'played' status
    else
      Rails.logger.warn "Evolution API: Unknown message status: #{status}"
      nil
    end
  end

  def handle_edited_content
    new_content = extract_edited_content
    return if new_content.blank?

    Rails.logger.info "Evolution API: Message #{raw_message_id} was edited"

    # Store the edit information
    content_attributes = @message.content_attributes || {}
    content_attributes[:edited] = true
    content_attributes[:edit_timestamp] = Time.current.to_i
    content_attributes[:original_content] = @message.content

    @message.update!(
      content: new_content,
      content_attributes: content_attributes
    )
    refresh_conversation_activity

    Rails.logger.debug 'Evolution API: Message content updated successfully'
  end

  def extract_edited_content
    msg = @raw_message[:message]
    return unless msg

    # Extract content from edited message following same pattern as original messages
    msg[:conversation] ||
      msg.dig(:extendedTextMessage, :text) ||
      msg.dig(:imageMessage, :caption) ||
      msg.dig(:videoMessage, :caption) ||
      msg.dig(:documentMessage, :caption)
  end

  def update_last_seen_at
    return unless @message.conversation&.contact

    # Update contact's last seen timestamp when they read a message
    @message.conversation.contact.update!(last_activity_at: Time.current)
  end

  def refresh_conversation_activity
    return unless @message&.respond_to?(:refresh_conversation_activity!)

    @message.refresh_conversation_activity!(@message.created_at, use_current_time: false)
  end
end
