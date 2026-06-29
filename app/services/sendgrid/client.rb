module Sendgrid
  # Outbound transport for SendGrid Mail Send (POST /v3/mail/send). The CRM
  # renders the template (Epic 6); this client is pure transport — it builds the
  # mail/send payload, posts it through the official sendgrid-ruby gem and maps
  # the provider response onto the message status (EVO-1251 / story 9.4).
  #
  # custom_args always carry contact_id / message_id / campaign_id so the inbound
  # event webhook (Sendgrid::EventProcessor) can recover context. The CRM owns
  # suppression, so mail_settings.bypass_unsubscribe_management is enabled (same
  # posture as BMS). The payload is built as a plain Hash because the gem's
  # MailSettings helper (6.7) does not model bypass_unsubscribe_management.
  class Client
    ACCEPTED_STATUS = 202
    INVALID_KEY_STATUSES = [401, 403].freeze
    MAX_LOGGED_BODY = 500
    REDACTED_4XX = '[redacted: 4xx body]'.freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    # Transport-layer failures from the gem's Net::HTTP client. Scoped on
    # purpose so a programming error never gets masked as "SendGrid unreachable".
    TRANSPORT_ERRORS = [SocketError, Timeout::Error, SystemCallError,
                        OpenSSL::SSL::SSLError, IOError, EOFError].freeze

    def initialize(channel)
      @channel = channel
    end

    # 202 -> message status 'sent' (provider accepted), returns success.
    # 4xx/5xx -> structured log (no recipient PII) + status 'failed', then raises.
    # transport failure -> status 'failed' + raises (the message must never be
    # left at the optimistic default 'sent' when the send did not happen).
    # All raises are Sendgrid::ApiError subclasses so the worker swallows them
    # without retry, with the message already flagged failed.
    def deliver(message:)
      response = post_mail_send(build_payload(message))
      handle_response(response, message)
    rescue Sendgrid::ServiceUnavailableError => e
      mark_failed(message, "SendGrid transport error: #{e.message}")
      raise
    end

    private

    def build_payload(message)
      conversation = message.conversation

      {
        personalizations: [{
          to: [{ email: conversation.contact.email }],
          custom_args: custom_args(message, conversation)
        }],
        from: from_field,
        reply_to: reply_to_field,
        subject: subject_for(conversation),
        content: [{ type: 'text/html', value: render_html(message) }],
        mail_settings: { bypass_unsubscribe_management: { enable: true } }
      }.compact
    end

    # Reuses the SMTP per-message template so SendGrid emails carry the same
    # markdown->HTML conversion, HTML pass-through detection, and channel
    # email_signature block as ConversationReplyMailer#email_reply (EVO-1721).
    # The mailer action itself is bypassed on purpose: it is gated by
    # smtp_config_set_or_development? (would short-circuit when SMTP is off),
    # mutates message.source_id (SendGrid tracks ids via custom_args), and
    # builds a mail() envelope we do not need.
    #
    # Caveat: ApplicationController.renderer pulls default_url_options from
    # action_controller, not action_mailer. The current template only references
    # ivars, so this is fine — but if anyone adds url_for/link_to/asset_url to
    # email_reply.html.erb, the SendGrid path may diverge from the SMTP path.
    # ActionMailer::Base.renderer would be the right tool but is not available
    # in this Rails version; ApplicationMailer.renderer is avoided because it
    # would route through MessageTemplate.resolver (DB overrides). The parity
    # spec ('matches ApplicationController.renderer ... byte-for-byte') is the
    # tripwire — it fails the moment template path / layout / assigns drift.
    # large_attachments is [] because attachments are out of scope for the
    # SendGrid channel (see EVO-1721 "Escopo — fora").
    def render_html(message)
      ApplicationController.renderer.render(
        template: 'mailers/conversation_reply_mailer/email_reply',
        layout: false,
        assigns: {
          message: message,
          channel: @channel,
          conversation: message.conversation,
          large_attachments: []
        }
      )
    end

    def custom_args(message, conversation)
      {
        contact_id: conversation.contact_id,
        message_id: message.id,
        campaign_id: message.additional_attributes&.dig('campaign_id')
      }.compact.transform_values(&:to_s)
    end

    def from_field
      field = { email: @channel.from_email }
      field[:name] = @channel.from_name if @channel.from_name.present?
      field
    end

    def reply_to_field
      return if @channel.reply_to.blank?

      { email: @channel.reply_to }
    end

    def subject_for(conversation)
      subject = conversation.additional_attributes&.dig('mail_subject')
      return subject if subject.present?

      "[##{conversation.display_id}] #{I18n.t('conversations.reply.email_subject')}"
    end

    def post_mail_send(payload)
      api.client.mail._('send').post(request_body: payload)
    rescue *TRANSPORT_ERRORS => e
      raise Sendgrid::ServiceUnavailableError.new("SendGrid request failed: #{e.message}", nil, nil)
    end

    def api
      @api ||= ::SendGrid::API.new(
        api_key: @channel.api_key,
        http_options: { open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT }
      )
    end

    def handle_response(response, message)
      status = response.status_code.to_i
      return accept(message, status) if status == ACCEPTED_STATUS

      reject(message, status, response)
    end

    def accept(message, status)
      Messages::StatusUpdateService.new(message, 'sent').perform
      { success: true, status: status }
    end

    def reject(message, status, response)
      Rails.logger.error(
        "[SENDGRID_MAIL_SEND] message_id=#{message.id} sg_response_status=#{status} body=#{safe_body(status, response)}"
      )
      reason = "SendGrid mail/send failed: #{status}"
      mark_failed(message, reason)
      raise error_for(status, reason, response)
    end

    def mark_failed(message, reason)
      Messages::StatusUpdateService.new(message, 'failed', reason).perform
    end

    def error_for(status, reason, response)
      return Sendgrid::InvalidApiKeyError.new(reason, status, response) if INVALID_KEY_STATUSES.include?(status)

      Sendgrid::ApiError.new(reason, status, response)
    end

    # 4xx bodies can echo the key or input, so the whole 4xx class is redacted;
    # 5xx bodies are length-bounded. The recipient address is never logged.
    def safe_body(status, response)
      return REDACTED_4XX if (400..499).cover?(status)

      body = response.body.to_s
      body.length > MAX_LOGGED_BODY ? "#{body[0, MAX_LOGGED_BODY]}... (truncated)" : body
    end
  end
end
