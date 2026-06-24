module Whatsapp::BaileysHandlers::MessagesUpdate
  include Whatsapp::BaileysHandlers::Helpers

  class MessageNotFoundError < StandardError; end

  private

  def process_messages_update
    updates = processed_params[:data]
    updates.each do |update|
      @message = nil
      @raw_message = update

      next handle_update if incoming?

      # NOTE: Shared lock with Whatsapp::SendOnWhatsappService
      # Avoids race conditions when sending messages.
      with_baileys_channel_lock_on_outgoing_message(inbox.channel.id) { handle_update }
    end
  end

  # EVO-1890: contact revokes arrive as a messages.delete event; mark the original
  # as revoked_by_contact (content kept + notice).
  def process_messages_delete
    data = processed_params[:data]
    return if data.blank?

    entries = data.is_a?(Array) ? data : [data]
    entries.each do |entry|
      source_id = entry[:id] || entry.dig(:key, :id)
      next if source_id.blank?

      Rails.logger.info "Baileys: messages.delete for #{source_id} — marking revoked_by_contact"
      mark_message_revoked_by_source_id(source_id)
    end
  end

  def handle_update
    raise MessageNotFoundError unless find_message_by_source_id(raw_message_id)

    update_status if @raw_message.dig(:update, :status).present?
    handle_edited_content if @raw_message.dig(:update, :message).present?
  end

  def update_status
    status = status_mapper
    update_last_seen_at if incoming? && status == 'read'
    return if status.blank?

    Messages::StatusUpdateService.new(@message, status).perform
  end

  def status_mapper
    # NOTE: Baileys status codes vs. Evolution support:
    #  - (0) ERROR         → (3) failed
    #  - (1) PENDING       → (0) sent
    #  - (2) SERVER_ACK    → (0) sent
    #  - (3) DELIVERY_ACK  → (1) delivered
    #  - (4) READ          → (2) read
    #  - (5) PLAYED        → (unsupported: PLAYED)
    # For details: https://github.com/WhiskeySockets/Baileys/blob/v6.7.16/WAProto/index.d.ts#L36694
    status = @raw_message.dig(:update, :status)
    case status
    when 0
      'failed'
    when 1, 2
      'sent'
    when 3
      'delivered'
    when 4
      'read'
    when 5
      Rails.logger.warn 'Baileys unsupported message update status: PLAYED(5)'
    else
      Rails.logger.warn "Baileys unsupported message update status: #{status}"
    end
  end

  def update_last_seen_at
    conversation = @message.conversation
    to_update = { agent_last_seen_at: Time.current }
    to_update[:assignee_last_seen_at] = Time.current if conversation.assignee_id.present?

    conversation.update_columns(to_update) # rubocop:disable Rails/SkipsModelValidations
  end

  def handle_edited_content
    @raw_message = @raw_message.dig(:update, :message, :editedMessage)
    content = message_content

    return @message.update!(content: content, is_edited: true, previous_content: @message.content) if content

    Rails.logger.warn 'No valid message content found in the edit event'
  end
end
