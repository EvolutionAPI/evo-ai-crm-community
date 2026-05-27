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
    # F-1: drop same-status re-emissions (duplicate webhooks would otherwise
    # publish bogus transitions; EvoFlow listener resolves event by
    # previous_status, so `delivered → delivered` would emit a false message.read).
    return false if message.status.to_s == status.to_s
    # F-2: read and failed are terminal — no transitions out.
    return false if message.read?
    return false if message.failed?
    # F-2: delivered must not regress to sent.
    return false if message.delivered? && status.to_s == 'sent'

    true
  end
end
