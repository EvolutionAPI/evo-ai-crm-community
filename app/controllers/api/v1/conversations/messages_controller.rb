class Api::V1::Conversations::MessagesController < Api::V1::Conversations::BaseController
  before_action :ensure_api_inbox, only: :update

  def index
    @messages = message_finder.perform

    success_response(
      data: MessageSerializer.serialize_collection(@messages, include_attachments: true, include_sender: true),
      message: 'Messages retrieved successfully'
    )
  end

  def create
    user = Current.user || @resource
    mb = Messages::MessageBuilder.new(user, @conversation, params)
    @message = mb.perform
    attach_canned_response_files if params[:canned_response_id].present?

    success_response(
      data: MessageSerializer.serialize(@message, include_attachments: true, include_sender: true),
      message: 'Message created successfully',
      status: :created
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to create message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def update
    @message = message
    previous_status = @message.status
    target_status = permitted_params[:status]
    return invalid_transition_response(previous_status, target_status) unless perform_status_update(target_status)

    success_response(
      data: MessageSerializer.serialize(@message.reload, include_attachments: true, include_sender: true),
      message: 'Message updated successfully'
    )
  rescue StandardError => e
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Failed to update message', details: e.message, status: :unprocessable_entity)
  end

  def destroy
    @message = message
    @message.update!(content_attributes: (@message.content_attributes || {}).merge(deleted: true))
    enqueue_provider_delete(@message)

    success_response(
      data: MessageSerializer.serialize(@message, include_attachments: true, include_sender: true),
      message: 'Message deleted successfully'
    )
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      'Message not found',
      status: :not_found
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to delete message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def retry
    @message = message

    # Reset to :sent directly (StatusUpdateService would reject the no-op
    # `sent → sent` Wisper publish anyway). Channel webhooks emit the
    # subsequent delivered/read events through the canonical funnel.
    @message.update!(status: :sent, content_attributes: {})

    ::SendReplyJob.perform_now(@message.id)

    success_response(
      data: MessageSerializer.serialize(@message.reload, include_attachments: true, include_sender: true),
      message: 'Message retry completed successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to retry message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  private

  # EVO-1891: when an agent deletes an OUTGOING message, revoke it on the provider
  # (delete-for-everyone) where supported. Done in a background job so a slow or
  # unreachable provider never blocks/delays the CRM soft-delete response.
  def enqueue_provider_delete(message)
    return unless message.outgoing?

    channel = message.conversation&.inbox&.channel
    return unless channel.respond_to?(:delete_message)

    Whatsapp::DeleteMessageOnProviderJob.perform_later(message.id)
  end

  def perform_status_update(target_status)
    Messages::StatusUpdateService.new(@message, target_status, permitted_params[:external_error]).perform
  end

  def invalid_transition_response(previous_status, target_status)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Invalid status transition',
      details: "#{previous_status} → #{target_status}",
      status: :unprocessable_entity
    )
  end

  def message
    @message ||= @conversation.messages.find(permitted_params[:id])
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, params, includes: message_includes)
  end

  def message_includes
    @message_includes ||= [
      :sender,
      :conversation,
      :inbox,
      :attachments
    ]
  end

  def permitted_params
    params.permit(:id, :status, :external_error)
  end

  # API inbox check
  def ensure_api_inbox
    # Only API inboxes can update messages
    return if @conversation.inbox.api?

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'Message status update is only allowed for API inboxes',
      status: :forbidden
    )
  end

  def attach_canned_response_files
    canned = CannedResponse.find_by(id: params[:canned_response_id])
    return unless canned

    canned.attachments.find_each do |att|
      new_att = @message.attachments.build(
        file_type: att.file_type,
        extension: att.extension,
        fallback_title: att.fallback_title,
        meta: att.meta,
        external_url: att.external_url
      )

      # reuse the SAME blob from ActiveStorage (no re-upload)
      new_att.file.attach(att.file.blob) if att.file.attached?
      new_att.save!
    end
  end
end
