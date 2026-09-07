# frozen_string_literal: true

module MailboxSanitizer
  private

  # Mail parsers can preserve NUL bytes in decoded headers and bodies, but
  # PostgreSQL text and JSONB columns cannot store them.
  def sanitize_mailbox_value(value)
    case value
    when String then value.delete("\u0000")
    when Array then value.map { |item| sanitize_mailbox_value(item) }
    when Hash then value.transform_values { |item| sanitize_mailbox_value(item) }
    else value
    end
  end
end
