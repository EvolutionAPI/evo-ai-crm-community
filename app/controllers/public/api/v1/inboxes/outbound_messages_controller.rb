# frozen_string_literal: true

# Public, internet-facing endpoint for sending an OUTGOING message into a
# conversation on the Channel::Api surface, optionally rendered from a
# MessageTemplate (EVO-1235 [6.6]).
#
# Auth is the Channel::Api `identifier` in the URL (+ optional HMAC), inherited
# from Public::Api::V1::InboxesController < PublicController. There is no
# Pundit/authorize and no API key on this path.
#
# Payload:
#   - message_template_id (preferred): resolved (global-aware) and rendered with
#     processed_params into the message content.
#   - content (deprecated): inline body; emits a WARN identifying the consumer.
class Public::Api::V1::Inboxes::OutboundMessagesController < Public::Api::V1::InboxesController
  include TemplateConsumerLogging

  def create
    return render_error('Conversation not found', :not_found) if @conversation.nil?

    if template_requested? && resolved_template.nil?
      return render_error('message_template_id not found or not available for this inbox',
                          :unprocessable_entity)
    end

    @message = @conversation.messages.create!(message_params)
    render json: serialized_message, status: :created
  rescue ArgumentError => e
    # Raised by MessageTemplate#render_with_variables when a required variable
    # is missing from processed_params.
    render_error(e.message, :unprocessable_entity)
  end

  private

  def message_params
    {
      sender: nil,
      content: outbound_content,
      inbox_id: @conversation.inbox_id,
      echo_id: permitted_params[:echo_id],
      message_type: :outgoing,
      additional_attributes: outbound_additional_attributes
    }
  end

  def outbound_content
    if template_requested?
      resolved_template.render_with_variables(processed_params)
    else
      warn_legacy_inline_content(action: 'outbound_messages#create', inbox_identifier: params[:inbox_id])
      permitted_params[:content]
    end
  end

  def outbound_additional_attributes
    return {} unless template_requested? && resolved_template

    # name is required by Message::TEMPLATE_PARAMS_SCHEMA.
    { template_params: { 'id' => resolved_template.id, 'name' => resolved_template.name, 'processed_params' => processed_params } }
  end

  def template_requested?
    permitted_params[:message_template_id].present?
  end

  def resolved_template
    return @resolved_template if defined?(@resolved_template)

    @resolved_template = MessageTemplates::SendResolver.new(
      id: permitted_params[:message_template_id],
      channel: @inbox_channel
    ).resolve
  end

  def processed_params
    permitted_params[:processed_params].to_h
  end

  def serialized_message
    {
      id: @message.id,
      content: @message.content,
      message_type: @message.message_type,
      conversation_id: @conversation.display_id,
      created_at: @message.created_at
    }
  end

  def render_error(message, status)
    render json: { error: message }, status: status
  end

  def permitted_params
    @permitted_params ||= params.permit(:content, :echo_id, :message_template_id, processed_params: {})
  end
end
