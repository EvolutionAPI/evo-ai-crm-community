class BounceMailbox < ApplicationMailbox
  # Parses RFC 3464 multipart/report; report-type=delivery-status messages,
  # looks up the original outbound Message by its Message-Id, and emits a
  # `:failed` status (via Messages::StatusUpdateService) when the DSN is a
  # permanent (5.x.x) failure. Transient (4.x.x) DSNs are logged only.
  def process
    return Rails.logger.warn('[BounceMailbox] No delivery-status part; dropping') if dsn_payload.blank?

    original_message_id = extract_original_message_id
    return Rails.logger.warn('[BounceMailbox] Missing Original-Message-ID; dropping') if original_message_id.blank?

    message = Message.find_by(source_id: original_message_id)
    return Rails.logger.warn("[BounceMailbox] No outbound message for #{original_message_id}") if message.nil?

    status_code, diagnostic_code = parse_dsn_fields
    if status_code&.start_with?('4.')
      Rails.logger.info("[BounceMailbox] Transient DSN #{status_code} for #{original_message_id}; not marking failed")
      return
    end

    Messages::StatusUpdateService.new(message, 'failed', diagnostic_code.presence || status_code).perform
  end

  private

  def dsn_payload
    @dsn_payload ||= mail.all_parts.find { |p| p.content_type&.include?('message/delivery-status') }
  end

  def extract_original_message_id
    extract_from_delivery_status || extract_from_attached_original
  end

  def extract_from_delivery_status
    raw = dsn_payload&.body&.decoded.to_s
    match = raw.match(/^Original-Message-ID:\s*<?([^>\s]+)>?/i) ||
            raw.match(/^X-Original-Message-ID:\s*<?([^>\s]+)>?/i)
    match&.[](1)
  end

  def extract_from_attached_original
    original_part = mail.all_parts.find { |p| p.content_type&.include?('message/rfc822') }
    original_part&.body&.decoded.to_s[/^Message-ID:\s*<?([^>\s]+)>?/i, 1]
  end

  def parse_dsn_fields
    raw = dsn_payload&.body&.decoded.to_s
    status = raw[/^Status:\s*([\d.]+)/i, 1]
    diagnostic = raw[/^Diagnostic-Code:\s*(.+)$/i, 1]
    [status, diagnostic&.strip]
  end
end
