class Telegram::SendOnTelegramService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Telegram
  end

  def perform_reply
    ## send reply to telegram message api
    # https://core.telegram.org/bots/api#sendmessage
    message_id = channel.send_message_on_telegram(message)
    message.update!(source_id: message_id) if message_id.present?

    # Telegram Bot API does not expose read receipts for general chats, so
    # `:read` is permanently unsupported here — we only emit `:delivered`.
    # Skip when the request already produced a failure (process_error) to
    # avoid emitting both `failed` and `delivered` in the same cycle.
    return unless message_id.present? && !message.failed?

    Messages::StatusUpdateService.new(message, 'delivered').perform
  end

  def inbox
    @inbox ||= message.inbox
  end

  def channel
    @channel ||= inbox.channel
  end
end
