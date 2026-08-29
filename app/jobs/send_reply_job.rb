class SendReplyJob < ApplicationJob
  queue_as :high

  def perform(message_id)
    message = Message.find(message_id)
    conversation = message.conversation
    channel_name = conversation.inbox.channel.class.to_s

    services = {
      'Channel::TwitterProfile' => ::Twitter::SendOnTwitterService,
      'Channel::TwilioSms' => ::Twilio::SendOnTwilioService,
      'Channel::Line' => ::Line::SendOnLineService,
      'Channel::Telegram' => ::Telegram::SendOnTelegramService,
      'Channel::Whatsapp' => ::Whatsapp::SendOnWhatsappService,
      'Channel::Sms' => ::Sms::SendOnSmsService,
      'Channel::Instagram' => ::Instagram::SendOnInstagramService
    }

    case channel_name
    when 'Channel::FacebookPage'
      send_on_facebook_page(message)
    else
      services[channel_name].new(message: message).perform if services[channel_name].present?
    end
  rescue ActiveRecord::RecordNotFound
    # Not a delivery failure: the row is either not visible to this connection yet
    # or gone for good. This clause exists to keep the `rescue StandardError` below
    # from swallowing it — that would mark the job done with the message still
    # unsent, no source_id and no external_error. Re-raise and let the retry decide,
    # logging first so a retry for this reason is not silent.
    Rails.logger.warn "[SendReplyJob] Message #{message_id} not found — leaving it to the retry"
    raise
  rescue StandardError => e
    Rails.logger.error "[SendReplyJob] Delivery failed for message #{message_id}: #{e.message}"
    mark_failed_through_funnel(message, e.message.to_s.truncate(1000)) if message
  end

  private

  # CRM-358: route through the status funnel (instead of a raw update) so
  # Wisper :message_status_changed reaches the EvoFlow listener — a provider
  # that raises (e.g. Evolution Go on HTTP error) lands here, not in
  # SendOnWhatsappService#handle_send_result. The marking itself must NEVER
  # raise out of the job's rescue: a validation failure (e.g. message flooding
  # runs on every save) would trigger a Sidekiq retry and RE-SEND a message
  # that may already be delivered. Last resort: raw column write, funnel bypassed
  # but no duplicate send.
  def mark_failed_through_funnel(message, reason)
    Messages::StatusUpdateService.new(message, 'failed', reason).perform
  rescue StandardError => e
    Rails.logger.error "[SendReplyJob] Could not mark message #{message.id} failed via funnel: #{e.message}"
    message.update_columns( # rubocop:disable Rails/SkipsModelValidations
      status: :failed,
      content_attributes: (message.content_attributes || {}).merge('external_error' => reason)
    )
  end

  def send_on_facebook_page(message)
    if message.conversation.additional_attributes['type'] == 'instagram_direct_message'
      ::Instagram::Messenger::SendOnInstagramService.new(message: message).perform
    elsif message.conversation.post_conversation? && !messenger_direct_message?(message)
      # For post conversations (but not Messenger direct messages), send as Facebook comment
      # Messenger direct messages have source_id starting with "m_"
      ::Facebook::SendCommentService.new(message: message).perform
    else
      # For regular messenger conversations or Messenger direct messages
      ::Facebook::SendOnFacebookService.new(message: message).perform
    end
  end

  def messenger_direct_message?(message)
    # Messenger direct messages have source_id starting with "m_"
    # Post comments have source_id in format like "692874516185238_1901363634120992"
    message.source_id.present? && message.source_id.start_with?('m_')
  end
end
