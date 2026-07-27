# frozen_string_literal: true

module BotRuntime
  # EVO-2227 (Fase 1.5): builds the media payload the bot_runtime forwards to the
  # AI agent as A2A file parts, straight from the PERSISTED message.
  #
  # Why this exists separately from DelegationService#build_attachments: the
  # delegation event is assembled inside the SYNC MESSAGE_CREATED listener, and it
  # gated media on `payload[:attachments].present?`. For an inbound WhatsApp voice
  # note that gate evaluated false (the dispatched payload had no :attachments
  # key), so the audio — though downloaded and attached to the message — never
  # reached the agent ("Total files extracted: 0" → 400). Re-reading the message's
  # real attachments at SEND time (async, in SendEventJob) makes the audio reach
  # the agent for ANY provider (native-audio models use the file; the transcription
  # from TranscriptionEnricher covers text-only models).
  class AttachmentBuilder
    ATTACHMENT_PRELOAD = { attachments: { file_attachment: :blob } }.freeze

    def self.build(message_id)
      new(message_id).build
    end

    def initialize(message_id)
      @message_id = message_id
    end

    def build
      return [] if @message_id.blank?

      message = Message.includes(ATTACHMENT_PRELOAD).find_by(id: @message_id)
      return [] if message.nil?

      message.attachments
             .sort_by { |att| [att.created_at, att.id.to_s] }
             .filter_map { |att| payload(att) }
    rescue StandardError => e
      Rails.logger.error("[BotRuntime::AttachmentBuilder] message=#{@message_id}: #{e.class}: #{e.message}")
      []
    end

    private

    # The bot_runtime fetches this URL server-side, so it's an outbound media URL
    # (BlobUrlOptions.outbound_media_url honors ACTIVE_STORAGE_URL and signs with a
    # short TTL). Rescued per attachment so one broken record doesn't drop the media
    # of the whole message.
    def payload(attachment)
      return if attachment.file_type.blank?
      return unless attachment.file.attached? && attachment.with_attached_file?

      blob = attachment.file.blob
      {
        url: BlobUrlOptions.outbound_media_url(blob),
        content_type: blob.content_type,
        file_type: attachment.file_type
      }
    rescue StandardError => e
      Rails.logger.error("[BotRuntime::AttachmentBuilder] attachment #{attachment.id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
