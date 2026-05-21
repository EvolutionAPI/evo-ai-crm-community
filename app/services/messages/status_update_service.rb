class Messages::StatusUpdateService
  include Wisper::Publisher

  attr_reader :message, :status, :external_error

  def initialize(message, status, external_error = nil)
    @message = message
    @status = status
    @external_error = external_error
  end

  def perform
    return false unless valid_status_transition?

    previous_status = message.status
    update_message_status
    # AC3 instrumentation: publish status transition so EvoFlow listener
    # can map (previous_status, status) → message.delivered/read/failed.
    publish(:message_status_changed, data: {
              message: message,
              previous_status: previous_status,
              status: status,
              external_error: external_error
            })
    true
  end

  private

  def update_message_status
    # Update status and set external_error in content_attributes when failed
    attrs = { status: status }
    if status == 'failed' && external_error.present?
      attrs[:content_attributes] = (message.content_attributes || {}).merge(external_error: external_error)
    end
    message.update!(attrs)
  end

  def valid_status_transition?
    return false unless Message.statuses.key?(status)

    # Don't allow changing from 'read' to 'delivered'
    return false if message.read? && status == 'delivered'

    true
  end
end
