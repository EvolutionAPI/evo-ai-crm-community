# frozen_string_literal: true

module BotRuntime
  # EVO-2227 (Fase 1): injects the audio transcription into the text content sent
  # to the AI agent, so a voice note is understood on ANY provider — not just
  # Gemini's native audio. The raw audio is still forwarded as a media part
  # (DelegationService#build_attachments), so Gemini keeps native understanding
  # while OpenAI (whose chat models reject inline audio) gets the transcript.
  #
  # Runs inside SendEventJob (async, off the inbound webhook request) because
  # AgentBotListener is on the SYNC dispatcher — transcribing there would block
  # the incoming-message request. Best-effort: any failure returns the event
  # unchanged so the agent call still happens.
  class TranscriptionEnricher
    LABEL = 'Transcrição do áudio'

    def self.enrich(event)
      new(event).enrich
    end

    def initialize(event)
      @event = event
    end

    def enrich
      transcribe_and_merge
    rescue StandardError => e
      Rails.logger.error("[BotRuntime::TranscriptionEnricher] #{e.class}: #{e.message}")
      @event
    end

    private

    def transcribe_and_merge
      message = target_message
      return @event if message.nil?

      audio_attachments = message.attachments.select(&:audio?)
      return @event if audio_attachments.empty?

      texts = audio_attachments.filter_map { |att| transcription_for(att) }
      return @event if texts.empty?

      @event.merge(message_content: combine(@event[:message_content], texts))
    end

    def target_message
      message_id = @event[:message_id]
      return if message_id.blank?

      Message.find_by(id: message_id)
    end

    # Reuse the transcription the display-path job may already have stored; only
    # transcribe now if it isn't there yet. The service is idempotent and persists
    # to meta, so a concurrent AudioTranscriptionJob converges on the same text.
    def transcription_for(attachment)
      existing = attachment.meta&.[]('transcribed_text')
      return existing if existing.present?

      result = Messages::AudioTranscriptionService.new(attachment: attachment).perform
      result[:transcribed_text] if result.is_a?(Hash) && result[:success]
    end

    def combine(original_content, texts)
      transcript = texts.map { |text| "[#{LABEL}]: #{text}" }.join("\n")
      base = original_content.to_s.strip
      base.empty? ? transcript : "#{base}\n\n#{transcript}"
    end
  end
end
