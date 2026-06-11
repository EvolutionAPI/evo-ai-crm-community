module Sendgrid
  # Dispatches an outbound email for a Channel::Sendgrid inbox through
  # Sendgrid::Client (EVO-1251 / story 9.4). Mirrors EmailReplyWorker for the
  # SMTP path. No retry this story: the client already logs and flags the
  # message failed, so the worker swallows the error instead of bubbling it.
  class SendEmailWorker
    include Sidekiq::Worker
    sidekiq_options queue: :mailers, retry: 0

    def perform(message_id)
      message = Message.find_by(id: message_id)
      return if message.nil?
      return unless message.email_notifiable_message?

      channel = message.conversation.inbox.channel
      return unless channel.is_a?(Channel::Sendgrid)

      Sendgrid::Client.new(channel).deliver(message: message)
    rescue Sendgrid::ApiError => e
      Rails.logger.warn("[SENDGRID_MAIL_SEND] swallowed #{e.class}: #{e.message}")
      nil
    rescue StandardError => e
      EvolutionExceptionTracker.new(e, account: nil).capture_exception
      Messages::StatusUpdateService.new(message, 'failed', e.message).perform if message
      nil
    end
  end
end
