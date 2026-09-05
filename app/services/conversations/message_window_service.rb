class Conversations::MessageWindowService
  MESSAGING_WINDOW_24_HOURS = 24.hours
  MESSAGING_WINDOW_7_DAYS = 7.days

  def initialize(conversation)
    @conversation = conversation
  end

  def can_reply?
    # Bypass messaging window in development environment
    return true if Rails.env.development?
    return true if messaging_window.blank?

    last_message_in_messaging_window?(messaging_window)
  end

  private

  def messaging_window
    # 🔒 PROTEÇÃO: Retornar nil se inbox ou channel não existir
    channel_type = @conversation.inbox&.channel_type
    return nil unless channel_type

    case channel_type
    when 'Channel::Api'
      api_messaging_window
    when 'Channel::FacebookPage'
      messenger_messaging_window
    when 'Channel::Instagram'
      instagram_messaging_window
    when 'Channel::Whatsapp'
      # Providers that allow free text messages are exempt from 24-hour window restriction
      free_text_providers = %w[evolution evolution_go]
      return if @conversation.inbox&.channel&.provider&.in?(free_text_providers)

      MESSAGING_WINDOW_24_HOURS
    when 'Channel::TwilioSms'
      twilio_messaging_window
    end
  end

  def last_message_in_messaging_window?(time)
    return false if last_incoming_message.nil?

    Time.current < last_incoming_message.created_at + time
  end

  def api_messaging_window
    return unless @conversation.inbox&.channel&.additional_attributes

    agent_reply_time_window = @conversation.inbox&.channel&.additional_attributes&.dig('agent_reply_time_window')
    return if agent_reply_time_window.blank?

    agent_reply_time_window.to_i.hours
  end

  # Check medium of the inbox to determine the messaging window
  def twilio_messaging_window
    @conversation.inbox&.channel&.medium == 'whatsapp' ? MESSAGING_WINDOW_24_HOURS : nil
  end

  def messenger_messaging_window
    meta_messaging_window('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT')
  end

  def instagram_messaging_window
    meta_messaging_window('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT')
  end

  def meta_messaging_window(config_key)
    GlobalConfigService.load(config_key, nil) ? MESSAGING_WINDOW_7_DAYS : MESSAGING_WINDOW_24_HOURS
  end

  def last_incoming_message
    @last_incoming_message ||= @conversation.messages&.incoming&.last
  end
end
