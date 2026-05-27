# == Schema Information
#
# Table name: channel_telegram
#
#  id         :uuid             not null, primary key
#  bot_name   :string
#  bot_token  :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_channel_telegram_on_bot_token  (bot_token) UNIQUE
#

class Channel::Telegram < ApplicationRecord
  TELEGRAM_HTTP_ERRORS = [
    HTTParty::Error,
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError,
    Errno::ECONNREFUSED,
    OpenSSL::SSL::SSLError
  ].freeze

  include Channelable
  include ChannelMessageTemplates

  self.table_name = 'channel_telegram'
  EDITABLE_ATTRS = [:bot_token].freeze

  before_validation :ensure_valid_bot_token, on: :create
  validates :bot_token, presence: true, uniqueness: true
  before_save :setup_telegram_webhook

  def name
    'Telegram'
  end

  def telegram_api_url
    "https://api.telegram.org/bot#{bot_token}"
  end

  def send_message_on_telegram(message)
    message_id = send_message(message) if message.content.present?
    message_id = Telegram::SendAttachmentsService.new(message: message).perform if message.attachments.present?
    message_id
  end

  def get_telegram_profile_image(user_id)
    # get profile image from telegram
    response = HTTParty.get("#{telegram_api_url}/getUserProfilePhotos", query: { user_id: user_id })
    return nil unless response.success?

    photos = response.parsed_response.dig('result', 'photos')
    return if photos.blank?

    get_telegram_file_path(photos.first.last['file_id'])
  end

  def get_telegram_file_path(file_id)
    response = HTTParty.get("#{telegram_api_url}/getFile", query: { file_id: file_id })
    return nil unless response.success?

    "https://api.telegram.org/file/bot#{bot_token}/#{response.parsed_response['result']['file_path']}"
  end

  def process_error(message, response)
    return unless response.parsed_response['ok'] == false

    # https://github.com/TelegramBotAPI/errors/tree/master/json
    external_error = "#{response.parsed_response['error_code']}, #{response.parsed_response['description']}"
    Messages::StatusUpdateService.new(message, 'failed', external_error).perform
  end

  def chat_id(message)
    message.conversation[:additional_attributes]['chat_id']
  end

  def reply_to_message_id(message)
    message.content_attributes['in_reply_to_external_id']
  end

  private

  def ensure_valid_bot_token
    response = HTTParty.get("#{telegram_api_url}/getMe")
    return add_invalid_token_error(response) unless response.success?

    assign_bot_name(response.parsed_response['result'])
  rescue *TELEGRAM_HTTP_ERRORS => e
    errors.add(:bot_token, "could not validate bot token: #{e.message}")
  end

  def setup_telegram_webhook
    backend_url = ENV.fetch('BACKEND_URL', nil) || ENV.fetch('FRONTEND_URL', nil)
    return abort_with_webhook_error('BACKEND_URL or FRONTEND_URL is missing') if backend_url.blank?

    HTTParty.post("#{telegram_api_url}/deleteWebhook")
    response = HTTParty.post("#{telegram_api_url}/setWebhook",
                             body: {
                               url: "#{backend_url}/webhooks/telegram/#{bot_token}"
                             })
    return if response.success?

    message = response.parsed_response&.dig('description').presence || 'unknown error'
    abort_with_webhook_error(message)
  rescue *TELEGRAM_HTTP_ERRORS => e
    abort_with_webhook_error("could not connect to Telegram API (#{e.message})")
  end

  def add_invalid_token_error(response)
    message = response.parsed_response&.dig('description').presence || 'invalid token'
    errors.add(:bot_token, message)
  end

  def assign_bot_name(result)
    if result.blank?
      errors.add(:bot_token, 'could not validate bot token')
      return
    end

    bot_name_value = result['first_name'].presence || result['username']
    Rails.logger.info(
      "[Channel::Telegram] Setting bot_name: #{bot_name_value.inspect} " \
      "(first_name: #{result['first_name'].inspect}, username: #{result['username'].inspect})"
    )
    self.bot_name = bot_name_value
  end

  def abort_with_webhook_error(message)
    errors.add(:bot_token, "error setting up the webhook: #{message}")
    throw(:abort)
  end

  def send_message(message)
    response = message_request(chat_id(message), message.content, reply_markup(message), reply_to_message_id(message))
    process_error(message, response)
    response.parsed_response['result']['message_id'] if response.success?
  end

  def reply_markup(message)
    return unless message.content_type == 'input_select'

    {
      one_time_keyboard: true,
      inline_keyboard: message.content_attributes['items'].map do |item|
        [{
          text: item['title'],
          callback_data: item['value']
        }]
      end
    }.to_json
  end

  def convert_markdown_to_telegram_html(text)
    # ref: https://core.telegram.org/bots/api#html-style
    telegram_allowed_tags = %w[b strong i em u ins s strike del a code pre blockquote]

    if html_content?(text)
      sanitized = Rails::HTML5::SafeListSanitizer.new.sanitize(
        text, tags: telegram_allowed_tags, attributes: %w[href]
      )
      sanitized
        .gsub(/<br\s*\/?>/, "\n")
        .gsub(%r{</p>\s*<p[^>]*>}, "\n")
        .gsub(%r{</?p[^>]*>}, '')
        .strip
    else
      text = CGI.escapeHTML(text.gsub("\n", '<br>'))
      html = CommonMarker.render_html(text).strip
      stripped_html = Rails::HTML5::SafeListSanitizer.new.sanitize(
        html, tags: telegram_allowed_tags, attributes: %w[href]
      )
      stripped_html.gsub('&lt;br&gt;', "\n")
    end
  end

  def html_content?(text)
    /<[a-z][\s\S]*>/i.match?(text)
  end

  def message_request(chat_id, text, reply_markup = nil, reply_to_message_id = nil)
    text_payload = convert_markdown_to_telegram_html(text)

    HTTParty.post("#{telegram_api_url}/sendMessage",
                  body: {
                    chat_id: chat_id,
                    text: text_payload,
                    reply_markup: reply_markup,
                    parse_mode: 'HTML',
                    reply_to_message_id: reply_to_message_id
                  })
  end
end
