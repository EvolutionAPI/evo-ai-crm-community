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

      # EVO-2227: fold the audio transcription into the text content here (async,
      # off the sync inbound-webhook path) so voice notes are understood on any
      # provider. Best-effort — the enricher returns the event unchanged on error.
      event = BotRuntime::TranscriptionEnricher.enrich(event)

      BotRuntime::Client.new.send_event(event)

      Rails.logger.info "[BotRuntime::SendEventJob] Event sent successfully: " \
                        "conversation_id=#{event[:conversation_id]}"
    end
  end
end
