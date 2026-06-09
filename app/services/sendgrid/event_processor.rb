# frozen_string_literal: true

module Sendgrid
  # Processes a single SendGrid event-webhook entry: dedups by sg_event_id,
  # resolves message context from custom_args, maps the event to an internal
  # Message status (reusing Messages::StatusUpdateService so the
  # :message_status_changed broadcast and EvoFlow tracking stay on one path)
  # and updates Contact email-suppression flags for negative terminal events.
  #
  # `unsubscribe` has no delivery-status equivalent, so it is handled as a
  # suppression-only event (no message-status transition).
  class EventProcessor
    DEDUP_TTL = 24.hours.to_i
    REQUIRED_ARGS = %w[contact_id message_id campaign_id].freeze

    EVENT_STATUS_MAP = {
      'delivered' => 'delivered',
      'open' => 'read',
      'click' => 'read',
      'bounce' => 'failed',
      'dropped' => 'failed',
      'spam_report' => 'failed'
    }.freeze

    SUPPRESSION_EVENTS = %w[bounce dropped spam_report unsubscribe].freeze

    METRIC_TOTAL = 'sendgrid:events:total'
    METRIC_DUPLICATE = 'sendgrid:events:duplicate_drops'
    METRIC_MISSING_ARGS = 'sendgrid:events:missing_args_drops'

    def initialize(event)
      @event = (event || {}).with_indifferent_access
    end

    # Returns a result symbol describing the outcome:
    # :processed | :duplicate | :missing_args | :ignored
    def process
      Redis::Alfred.incr(METRIC_TOTAL)

      return drop_duplicate unless claim_event

      Redis::Alfred.incr("sendgrid:events:type:#{event_type}")

      return drop_missing_args unless custom_args_present?

      handle_event
      :processed
    end

    private

    attr_reader :event

    def handle_event
      apply_status_change
      apply_suppression
    rescue StandardError
      # Release the dedup claim so a SendGrid resend can be retried — a
      # transient write failure must not permanently swallow the event.
      release_claim
      raise
    end

    def claim_event
      if sg_event_id.blank?
        Rails.logger.warn("[SENDGRID_WEBHOOK] event without sg_event_id; processing without dedup event=#{event_type.inspect}")
        return true
      end

      Redis::Alfred.set(dedup_key, 1, nx: true, ex: DEDUP_TTL)
    end

    def release_claim
      return if sg_event_id.blank?

      Redis::Alfred.delete(dedup_key)
    end

    def drop_duplicate
      Redis::Alfred.incr(METRIC_DUPLICATE)
      :duplicate
    end

    def drop_missing_args
      Redis::Alfred.incr(METRIC_MISSING_ARGS)
      Rails.logger.warn(
        '[SENDGRID_WEBHOOK] dropping event with missing custom_args ' \
        "sg_event_id=#{sg_event_id.inspect} event=#{event_type.inspect} payload=#{event.to_h.inspect}"
      )
      :missing_args
    end

    def apply_status_change
      status = EVENT_STATUS_MAP[event_type]
      return if status.nil?

      message = Message.find_by(id: custom_args[:message_id])
      return warn_missing('message', custom_args[:message_id]) unless message

      Messages::StatusUpdateService.new(message, status, external_error).perform
    end

    def apply_suppression
      return unless SUPPRESSION_EVENTS.include?(event_type)

      contact = Contact.find_by(id: custom_args[:contact_id])
      return warn_missing('contact', custom_args[:contact_id]) unless contact

      contact.update!(email_suppressed: true, email_suppression_reason: event_type)
    end

    def external_error
      return nil unless EVENT_STATUS_MAP[event_type] == 'failed'

      event[:reason].presence || event_type
    end

    def custom_args_present?
      REQUIRED_ARGS.all? { |key| custom_args[key].present? }
    end

    def custom_args
      @custom_args ||= (event[:custom_args] || {}).with_indifferent_access
    end

    def event_type
      event[:event].to_s
    end

    def sg_event_id
      event[:sg_event_id].to_s
    end

    def dedup_key
      "sendgrid:event:#{sg_event_id}"
    end

    def warn_missing(kind, id)
      Rails.logger.warn(
        "[SENDGRID_WEBHOOK] #{kind} not found for sg_event_id=#{sg_event_id.inspect} #{kind}_id=#{id.inspect}"
      )
      nil
    end
  end
end
