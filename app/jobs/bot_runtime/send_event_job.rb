# frozen_string_literal: true

module BotRuntime
  class SendEventJob < ApplicationJob
    queue_as :bot_runtime
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    discard_on BotRuntime::CircuitBreaker::CircuitOpenError do |_job, error|
      Rails.logger.warn "[BotRuntime::SendEventJob] Discarded: #{error.message}"
    end

    def perform(event)
      Rails.logger.info "[BotRuntime::SendEventJob] Sending event: " \
                        "conversation_id=#{event[:conversation_id]} agent_bot_id=#{event[:agent_bot_id]}"

      # EVO-2227 Fase 1.5: re-read the message's real attachments at send time
      # (async, after the media is persisted) so the audio FILE reaches the agent —
      # the sync-listener build gated media out. Native-audio providers use the file.
      event = refresh_attachments(event)

      # EVO-2227 Fase 1: fold the audio transcription into the text content here
      # (async, off the sync inbound-webhook path) so voice notes are also understood
      # by text-only providers. Best-effort — returns the event unchanged on error.
      event = BotRuntime::TranscriptionEnricher.enrich(event)

      BotRuntime::Client.new.send_event(event)

      Rails.logger.info "[BotRuntime::SendEventJob] Event sent successfully: " \
                        "conversation_id=#{event[:conversation_id]}"
    end

    private

    # Override the event's media with the message's real, persisted attachments.
    # Best-effort: a blank result (no media, or a lookup error) leaves the event
    # untouched so a text-only delegation is unaffected.
    def refresh_attachments(event)
      message_id = event[:message_id]
      return event if message_id.blank?

      attachments = BotRuntime::AttachmentBuilder.build(message_id)
      return event if attachments.blank?

      Rails.logger.info "[BotRuntime::SendEventJob] Forwarding #{attachments.size} attachment(s) for message #{message_id}"
      event.merge(attachments: attachments)
    rescue StandardError => e
      Rails.logger.error "[BotRuntime::SendEventJob] refresh_attachments failed: #{e.class}: #{e.message}"
      event
    end
  end
end
