require 'securerandom'

# Shared send handlers for stage automation actions, usable by BOTH the
# event-driven path (Pipelines::StageAutomationService) and the time-based
# inactivity path (Pipelines::StageInactivityActionsService). Each handler
# takes an already-resolved Conversation as its target.
module Pipelines::StageMessageActions
  AUTOMATION_SOURCE = 'stage_inactivity_action'.freeze

  # Ask the inbox's evo_ai agent bot to generate a contextual re-engagement
  # message. Falls back to a direct message when no evo_ai bot is available and
  # a literal text was provided. Mirrors AgentBots::InactivityActionsService.
  def send_ai_message(conversation, suggested_message: nil, source: AUTOMATION_SOURCE)
    agent_bot = conversation.inbox&.agent_bot
    unless agent_bot&.evo_ai_provider?
      if suggested_message.present?
        Rails.logger.info '[StageMessageActions] no evo_ai bot on inbox, falling back to direct message'
        return send_direct_message(conversation, suggested_message, source: source)
      end
      Rails.logger.warn "[StageMessageActions] send_ai_message skipped: inbox #{conversation.inbox_id} has no evo_ai bot and no fallback text"
      return false
    end

    agent_bot_inbox = conversation.inbox.agent_bot_inbox
    if agent_bot_inbox.present? && !agent_bot_inbox.should_process_conversation?(conversation)
      Rails.logger.warn "[StageMessageActions] send_ai_message skipped: conv #{conversation.id} does not match bot criteria"
      return false
    end

    AgentBots::HttpRequestService.new(agent_bot, build_ai_payload(conversation, suggested_message)).perform
    true
  end

  def send_direct_message(conversation, text, source: AUTOMATION_SOURCE)
    return false if text.blank?

    build_outgoing_message(conversation, text, source)
    true
  end

  # template_params: Hash with `id` (preferred) or `name`+`language`+`namespace`
  # +`processed_params`. Resolved/rendered by MessageBuilder + SendResolver.
  def send_template(conversation, template_params, source: AUTOMATION_SOURCE)
    return false if template_params.blank?

    ::Messages::MessageBuilder.new(
      nil, conversation,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content: '',
      template_params: template_params,
      content_attributes: { automation_source: source }
    ).perform
    true
  end

  def finalize(conversation, text = nil, source: "#{AUTOMATION_SOURCE}_finalize")
    return false unless conversation

    conversation.resolved! unless conversation.resolved?
    build_outgoing_message(conversation, text, source) if text.present?
    true
  end

  private

  def build_outgoing_message(conversation, text, source)
    sender = conversation.inbox&.agent_bot
    ::Messages::MessageBuilder.new(
      nil, conversation,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content: text,
      sender: sender,
      content_attributes: { automation_source: source }
    ).perform
  end

  def build_ai_payload(conversation, suggested_message)
    inbox = conversation.inbox
    {
      event: 'inactivity_action',
      id: SecureRandom.uuid,
      message_type: 'incoming',
      content: ai_prompt(suggested_message),
      conversation: conversation.webhook_data.merge(id: conversation.id),
      conversation_id: conversation.id,
      inbox: inbox.webhook_data,
      inbox_id: inbox.id,
      sender: conversation.contact.webhook_data,
      contact_id: conversation.contact.id,
      created_at: Time.current.to_i,
      inactivity_metadata: {
        action_type: 'interact',
        source: 'stage_inactivity',
        suggested_message: suggested_message,
        is_system_prompt: true
      }
    }
  end

  def ai_prompt(suggested_message)
    base = '<system_message>[SYSTEM - INACTIVITY ACTION] The customer has been inactive. ' \
           'Generate a proactive, natural message to re-engage them, relevant to the conversation context.'
    base += " Suggestion: #{suggested_message}" if suggested_message.present?
    base + '<important>Reply ONLY with the message text for the customer. Do NOT use tools. ' \
           'Do NOT add meta-commentary.</important></system_message>'
  end
end
