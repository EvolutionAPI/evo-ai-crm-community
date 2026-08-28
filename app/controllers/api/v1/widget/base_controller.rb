class Api::V1::Widget::BaseController < ApplicationController
  include SwitchLocale
  include WebsiteTokenHelper

  before_action :set_web_widget
  before_action :set_contact

  private

  def conversations
    @conversations ||= begin
      if @contact_inbox.hmac_verified?
        verified_ids = @contact.contact_inboxes
          .where(inbox_id: inbox.id, hmac_verified: true)
          .pluck(:id)

        # ✅ sempre inclui o contact_inbox atual (do token), mesmo se não estiver verificado
        ids = (verified_ids + [@contact_inbox.id]).uniq

        conversations_scope.where(contact_inbox_id: ids)
      else
        # ✅ conversa do contact_inbox atual
        conversations_scope.where(contact_inbox_id: @contact_inbox.id)
      end
    end
  end

  def conversations_scope
    # Escopo base de conversas do contato no inbox atual
    Conversation.where(contact_id: @contact.id, inbox_id: inbox.id)
  end

  def conversation
    @conversation ||= begin
      conversation_id = permitted_params.dig(:message, :conversation_id)

      if conversation_id.present?
        # ✅ Busca primeiro pelo ID UUID
        conv = conversations.find_by(id: conversation_id)
        return conv if conv

        # ✅ Fallback: se conversation_id é numérico, tenta buscar por display_id
        if conversation_id.to_s.match?(/\A\d+\z/)
          conv = conversations.find_by(display_id: conversation_id.to_i)
          return conv if conv
        end

        # Não encontrou
        nil
      else
        # Busca conversa aberta/pendente ou a mais recente
        conversations.where(status: [:open, :pending]).order(created_at: :desc).first ||
          conversations.order(created_at: :desc).first
      end
    end
  end


  def create_conversation
    ::Conversation.create!(conversation_params)
  end

  def inbox
    @inbox ||= @web_widget.inbox
  end

  def conversation_params
    # Use sanitized custom attributes if available
    custom_attrs = if defined?(@sanitized_custom_attributes) && @sanitized_custom_attributes
                     @sanitized_custom_attributes
                   else
                     permitted_params[:custom_attributes].presence || {}
                   end

    # FIXME: typo referrer in additional attributes, will probably require a migration.
    {
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: {
        browser_language: browser.accept_language&.first&.code,
        browser: browser_params,
        initiated_at: timestamp_params,
        referer: permitted_params[:message][:referer_url]
      },
      custom_attributes: custom_attrs
    }
  end

  def contact_email
    permitted_params.dig(:contact, :email)&.downcase || @contact.email.presence
  end

  def contact_name
    return if @contact.email.present? || @contact.phone_number.present? || @contact.identifier.present?

    permitted_params.dig(:contact, :name) || (contact_email.split('@')[0] if contact_email.present?)
  end

  def contact_phone_number
    # Falls back to the already-identified contact's own phone number — the
    # frontend correctly omits already-known fields from the pre-chat payload
    # (PreChatForm filters fields where has_phone_number/has_email is true),
    # so requiring them again here made pre-chat validation fail for every
    # returning contact starting a new conversation once pre-chat fields are
    # marked required (EVO-2233).
    permitted_params.dig(:contact, :phone_number) || @contact.phone_number.presence
  end

  def browser_params
    {
      browser_name: browser.name,
      browser_version: browser.full_version,
      device_name: browser.device.name,
      platform_name: browser.platform.name,
      platform_version: browser.platform.version
    }
  end

  def timestamp_params
    { timestamp: permitted_params[:message][:timestamp] }
  end

  def message_params
    # Use sanitized message content if available
    message_content = if defined?(@sanitized_message_content) && @sanitized_message_content
                        @sanitized_message_content
                      else
                        permitted_params[:message][:content]
                      end

    {
      sender: @contact,
      content: message_content,
      inbox_id: conversation.inbox_id,
      content_attributes: {
        in_reply_to: permitted_params[:message][:reply_to]
      },
      echo_id: permitted_params[:message][:echo_id],
      message_type: :incoming
    }
  end
end
