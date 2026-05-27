module Whatsapp::EvolutionGoHandlers::ReceiptHandler
  include Whatsapp::EvolutionGoHandlers::Helpers

  private

  def process_read_receipt
    Rails.logger.info 'Evolution Go API: Processing Receipt event'

    receipt_data = processed_params[:data]
    return if receipt_data.blank?

    event_state = processed_params[:state]
    return if event_state.blank?

    Rails.logger.info "Evolution Go API: Receipt state: #{event_state}"
    Rails.logger.debug { "Evolution Go API: Receipt data: #{receipt_data.inspect}" }

    # Extract message IDs and status
    message_ids = receipt_data[:MessageIDs]
    return if message_ids.blank?

    Rails.logger.info "Evolution Go API: Processing receipt for #{message_ids.size} message(s)"

    # Map Evolution Go receipt state to Evolution status
    status = map_receipt_state_to_status(event_state, receipt_data[:Type])
    return unless status

    # Process receipts efficiently based on count
    if message_ids.size > 10
      process_bulk_receipts(message_ids, status, receipt_data)
    else
      message_ids.each do |message_id|
        process_single_receipt(message_id, status, receipt_data)
      end
    end
  end

  def process_bulk_receipts(message_ids, status, _receipt_data)
    # Efficient bulk processing for large receipt batches
    Rails.logger.info "Evolution Go API: Processing bulk receipt for #{message_ids.size} messages"

    # Find all messages at once
    messages = inbox.messages.where(source_id: message_ids)
    found_ids = messages.pluck(:source_id)
    missing_ids = message_ids - found_ids

    if missing_ids.any?
      Rails.logger.warn "Evolution Go API: Missing messages for receipt: #{missing_ids.first(5).join(', ')}#{missing_ids.size > 5 ? " and #{missing_ids.size - 5} more" : ''}"
    end

    bulk_update_and_publish(messages.select { |msg| can_update_message_status?(msg, status) }, status)

    # Update contact activity for outgoing messages
    outgoing_messages = messages.outgoing
    return unless outgoing_messages.any?

    contacts = Contact.joins(:contact_inboxes)
                      .where(conversations: { id: outgoing_messages.select(:conversation_id).distinct })
                      .distinct

    contacts.update_all(last_activity_at: Time.current)
  end

  # Capture previous_status BEFORE update_all so per-row Wisper events report
  # accurate transitions. The publish loop runs OUTSIDE the transaction so a
  # listener failure does not roll back the DB write.
  def bulk_update_and_publish(updatable_messages, status)
    return if updatable_messages.empty?

    previous_by_id = updatable_messages.to_h { |m| [m.id, m.status] }
    Message.transaction do
      Message.where(id: previous_by_id.keys).update_all(status: status) # rubocop:disable Rails/SkipsModelValidations
    end

    # canonical: Messages::StatusUpdateService#perform — inlined here to
    # preserve bulk update_all performance.
    publisher = Whatsapp::EvolutionGoHandlers::BulkStatusPublisher.new
    Message.where(id: previous_by_id.keys).find_each do |m|
      publisher.emit(m, previous_by_id[m.id], status)
      Rails.logger.debug { "Evolution Go API: Bulk updated message #{m.source_id} to #{status}" }
    end
  end

  def process_single_receipt(message_id, status, _receipt_data)
    message = find_message_by_source_id_for_receipt(message_id, _receipt_data)
    return unless message && can_update_message_status?(message, status)

    Messages::StatusUpdateService.new(message, status).perform
    Rails.logger.debug { "Evolution Go API: Updated message #{message.source_id} to #{status}" }
  end

  def find_message_by_source_id_for_receipt(message_id, _receipt_data)
    message = inbox.messages.find_by(source_id: message_id)

    if message
      Rails.logger.debug do
        "Evolution Go API: Found message: #{message.id}, current status: #{message.status}, message_type: #{message.message_type}"
      end
    else
      Rails.logger.debug { "Evolution Go API: Message not found in inbox #{inbox.id} with source_id: #{message_id}" }
    end

    message
  end

  # Pre-bulk filter — necessary because `bulk_update_and_publish` uses
  # `update_all` and cannot rely on the canonical funnel
  # (`Messages::StatusUpdateService`) to reject invalid transitions after
  # the fact. Rules mirror the funnel: same-status / read final / failed
  # final get filtered out before the bulk write.
  def can_update_message_status?(message, new_status)
    current_status = message.status.to_s
    return false if current_status == new_status.to_s
    return false if current_status == 'read'
    return false if current_status == 'failed'
    return false if current_status == 'delivered' && new_status.to_s == 'sent'

    true
  end

  def map_receipt_state_to_status(state, _type)
    case state.downcase
    when 'read'
      'read'
    when 'delivered'
      'delivered'
    else
      Rails.logger.warn "Evolution Go API: Unknown receipt state: #{state}"
      nil
    end
  end
end
