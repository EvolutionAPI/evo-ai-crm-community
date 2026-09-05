# frozen_string_literal: true

module BotRuntime
  class DelegationService
    # A constant so the spec can walk it against the real reflections: a renamed
    # association makes build_attachments rescue to [], indistinguishable from "no
    # media sent".
    ATTACHMENT_PRELOAD = { attachments: { file_attachment: :blob } }.freeze

    # has_attachments defaults to true so a caller that omits it still looks for
    # media instead of silently skipping it.
    def initialize(agent_bot, message, conversation, has_attachments: true)
      @agent_bot = agent_bot
      @message = message
      @conversation = conversation
      @has_attachments = has_attachments
    end

    def delegate
      event = build_message_event
      BotRuntime::SendEventJob.perform_later(event)

      Rails.logger.info "[BotRuntime::DelegationService] Event enqueued: " \
                        "conversation=#{@conversation.display_id} bot=#{@agent_bot.name}"
    end

    private

    def build_message_event
      {
        agent_bot_id: @agent_bot.id,
        conversation_id: @conversation.display_id,
        contact_id: stable_contact_id,
        message_id: @message.id.to_s,
        message_content: @message.content.to_s,
        attachments: build_attachments,
        api_key: AgentBots::CredentialResolution.api_key_for(@agent_bot).to_s,
        outgoing_url: @agent_bot.outgoing_url.to_s,
        bot_config: build_bot_config,
        postback_url: build_postback_url,
        metadata: build_metadata
      }
    end

    # EVO-2179: forward incoming media (image/audio/…) so the bot_runtime can pass
    # it to the AI processor as A2A file parts. Without this a media-only message
    # reaches the AI empty ("No content to process") — the agent never sees it.
    #
    # @message is an unpersisted Message.new with only the id set (see
    # AgentBotListener#create_message_from_payload), so its attachments are empty —
    # hence the reload. Gated on the payload, or every text message pays two queries
    # for a result that is always [].
    #
    # created_at orders media across a debounce window; the id is only a tie-break,
    # not send order (random UUID), which is fine as the inbound handlers create one
    # attachment per message.
    def build_attachments
      return [] unless @has_attachments

      persisted = @conversation.messages
                               .includes(ATTACHMENT_PRELOAD)
                               .find_by(id: @message.id)
      return [] if persisted.nil?

      persisted.attachments
               .sort_by { |att| [att.created_at, att.id.to_s] }
               .filter_map { |att| attachment_payload(att) }
    rescue StandardError => e
      log_attachment_failure('build_attachments', e)
      []
    end

    # The bot_runtime fetches this URL server-side, so it is an outbound media URL
    # like the ones handed to Evolution API / Evolution Go — not a browser URL.
    # BlobUrlOptions.outbound_media_url honors ACTIVE_STORAGE_URL (the host a
    # sibling container can reach; BACKEND_URL is browser-facing and is not
    # required to resolve inside the network) and signs the link with a 15-minute
    # TTL instead of the permanent signed id of Attachment#download_url. The TTL
    # covers the debounce window (seconds) plus the SendEventJob retries.
    #
    # Rescued per attachment: one broken record (a NULL file_type makes
    # with_attached_file? raise) must not drop the media of the whole message.
    def attachment_payload(att)
      return if att.file_type.blank?
      return unless att.file.attached? && att.with_attached_file?

      blob = att.file.blob
      {
        url: BlobUrlOptions.outbound_media_url(blob),
        content_type: blob.content_type,
        file_type: att.file_type
      }
    rescue StandardError => e
      log_attachment_failure("attachment #{att.id}", e)
      nil
    end

    def log_attachment_failure(context, error)
      Rails.logger.error(
        "[BotRuntime::DelegationService] #{context} failed " \
        "(message=#{@message.id} conversation=#{@conversation.display_id}): " \
        "#{error.class}: #{error.message}"
      )
    end

    def build_bot_config
      {
        debounce_time: @agent_bot.debounce_time || 0,
        message_signature: @agent_bot.message_signature.to_s,
        text_segmentation_enabled: @agent_bot.text_segmentation_enabled || false,
        text_segmentation_limit: @agent_bot.text_segmentation_limit || 300,
        text_segmentation_min_size: @agent_bot.text_segmentation_min_size || 50,
        delay_per_character: (@agent_bot.delay_per_character || 50).to_f
      }
    end

    def build_postback_url
      "#{BotRuntime::Config.postback_base_url}/webhooks/bot_runtime/postback/#{@conversation.display_id}"
    end

    def build_metadata
      contact = @conversation.contact
      {
        evoai_crm_event: 'message_created',
        evoai_crm_data: {
          event: 'message_created',
          conversation_id: @conversation.id,
          conversation: { id: @conversation.id, display_id: @conversation.display_id },
          inbox: { id: @conversation.inbox.id, name: @conversation.inbox.name },
          contact: { id: contact.id, name: contact.name }
        },
        agent_bot_id: @agent_bot.id,
        agent_bot_name: @agent_bot.name,
        contactId: contact.id,
        contactName: contact.name,
        inboxId: @conversation.inbox.id,
        contact: build_contact_data(contact)
      }
    end

    def build_contact_data(contact)
      {
        id: contact.id.to_s,
        name: contact.name,
        email: contact.email,
        phone_number: contact.phone_number,
        identifier: contact.identifier,
        type: contact.type,
        contact_type: contact.contact_type,
        blocked: contact.blocked,
        location: contact.location,
        country_code: contact.country_code,
        additional_attributes: contact.additional_attributes || {},
        custom_attributes: contact.custom_attributes || {},
        labels: contact.labels.pluck(:name)
      }
    end

    # Generate a deterministic int64 from the UUID contact_id.
    # Uses SHA256 truncated to 8 bytes, masked to positive int64.
    # Deterministic across processes and restarts (unlike String#hash).
    def stable_contact_id
      digest = Digest::SHA256.digest(@conversation.contact_id.to_s)
      digest.unpack1('Q>') & 0x7FFFFFFFFFFFFFFF
    end
  end
end
