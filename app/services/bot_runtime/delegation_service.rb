# frozen_string_literal: true

module BotRuntime
  class DelegationService
    def initialize(agent_bot, message, conversation)
      @agent_bot = agent_bot
      @message = message
      @conversation = conversation
    end

    def delegate
      event = build_message_event
      Rails.configuration.dispatcher.dispatch("conversation.typing_on", Time.zone.now, conversation: @conversation, user: @agent_bot, is_private: false)
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
        api_key: @agent_bot.api_key.to_s,
        outgoing_url: @agent_bot.outgoing_url.to_s,
        bot_config: build_bot_config,
        postback_url: build_postback_url,
        metadata: build_metadata
      }
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
