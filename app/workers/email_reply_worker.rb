class EmailReplyWorker
  include Sidekiq::Worker
  sidekiq_options queue: :mailers, retry: 3

  def perform(message_id)
    message = Message.find(message_id)

    return unless message.email_notifiable_message?

    mail = deliver_email(message)
    return if mail.nil? # delivery already marked the message as failed

    # Capture the outbound Message-Id so BounceMailbox can match DSN lookups
    # by source_id.
    captured_id = mail.message_id if mail.respond_to?(:message_id)
    message.update!(source_id: captured_id) if message.source_id.blank? && captured_id.present?

    # Optimistic delivered: deliver_now returning without raising means the
    # SMTP server accepted the envelope. Async DSN bounces will flip to failed.
    Messages::StatusUpdateService.new(message, 'delivered').perform
  end

  private

  def deliver_email(message)
    ConversationReplyMailer.with(account: nil).email_reply(message).deliver_now
  rescue StandardError => e
    EvolutionExceptionTracker.new(e, account: nil).capture_exception
    Messages::StatusUpdateService.new(message, 'failed', e.message).perform
    nil
  end
end
