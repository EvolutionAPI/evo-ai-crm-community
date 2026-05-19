# frozen_string_literal: true

class Webhooks::BotRuntimeController < ActionController::API
  before_action :validate_secret

  def postback
    conversation = Conversation.find_by(display_id: params[:conversation_display_id])
    unless conversation
      render json: { error: 'Conversation not found' }, status: :not_found
      return
    end

    agent_bot = find_active_agent_bot(conversation)
    unless agent_bot
      render json: { error: 'No active agent bot for this conversation' }, status: :not_found
      return
    end

    content = params[:content]
    if content.blank?
      render json: { error: 'Content is required' }, status: :bad_request
      return
    end

    content_type = params[:content_type].presence || 'text'
    raw_items    = params[:items]
    content_attributes = nil

    if content_type == 'input_select' && raw_items.present?
      items = raw_items.map { |item| { title: item[:title].to_s, value: item[:value].to_s } }
      content_attributes = { items: items }
    end

    message = AgentBots::MessageCreator.new(agent_bot).create_bot_reply(
      content, conversation,
      content_type: content_type,
      content_attributes: content_attributes
    )

    if message
      Rails.logger.info "[BotRuntime::Postback] Message created: #{message.id} conversation=#{conversation.display_id}"
      render json: { status: 'sent' }, status: :ok
    else
      Rails.logger.warn "[BotRuntime::Postback] Message creation failed: conversation=#{conversation.display_id}"
      render json: { error: 'Message creation failed' }, status: :unprocessable_entity
    end
  end

  private

  def validate_secret
    expected_secret = BotRuntime::Config.secret

    # Skip validation when no secret is configured (development/testing)
    return if expected_secret.blank?

    provided_secret = request.headers['X-Bot-Runtime-Secret']
    return if provided_secret == expected_secret

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def find_active_agent_bot(conversation)
    inbox = conversation.inbox
    agent_bot_inbox = inbox.agent_bot_inbox
    return nil unless agent_bot_inbox&.active?

    agent_bot_inbox.agent_bot
  end
end
