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
    message&.update(status: :failed, external_error: e.message.to_s.truncate(1000))
  end

  private

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
