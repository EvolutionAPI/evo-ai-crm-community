# frozen_string_literal: true

# Emits a structured WARN when an external consumer of a public messaging
# endpoint still sends inline `content` instead of a `message_template_id`,
# so the legacy callers can be identified and migrated during the coexistence
# period (EVO-1235 [6.6]).
#
# The consumer identifier comes from the client-supplied `X-Client-ID` header,
# falling back to the request IP. NOTE: `X-Client-ID` is untrusted (it is a
# plain request header) — it is for telemetry only, never for authorization.
module TemplateConsumerLogging
  extend ActiveSupport::Concern

  private

  def warn_legacy_inline_content(action:, inbox_identifier:)
    Rails.logger.warn(
      '[templates] deprecated inline content; ' \
      "consumer=#{template_consumer_identifier} inbox=#{inbox_identifier} action=#{action}"
    )
  end

  def template_consumer_identifier
    request.headers['X-Client-ID'].presence || request.remote_ip
  end
end
