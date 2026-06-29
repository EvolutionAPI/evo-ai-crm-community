# == Schema Information
#
# Table name: channel_sendgrid
#
#  id                          :uuid             not null, primary key
#  api_key_encrypted           :text             not null
#  email_signature             :text
#  from_email                  :string           not null
#  from_name                   :string
#  reply_to                    :string
#  sender_domain               :string
#  webhook_registration_status :string           default("pending"), not null
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#
# Indexes
#
#  index_channel_sendgrid_on_from_email  (from_email)
#

class Channel::Sendgrid < ApplicationRecord
  include Channelable

  self.table_name = 'channel_sendgrid'

  EDITABLE_ATTRS = [:api_key, :from_email, :from_name, :reply_to, :sender_domain, :email_signature].freeze

  DOMAIN_FORMAT = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/i

  WEBHOOK_STATUSES = %w[pending active failed].freeze

  validates :api_key, presence: true
  validates :from_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :reply_to, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :sender_domain, format: { with: DOMAIN_FORMAT }, allow_blank: true
  validates :webhook_registration_status, inclusion: { in: WEBHOOK_STATUSES }

  # The smoke test (401/403) must gate persistence, so it runs before save and
  # lets Sendgrid::InvalidApiKeyError propagate out of create!/update! to the
  # controller. Webhook registration runs after save (rescued) so a SendGrid
  # outage marks the channel `failed` instead of aborting a valid key. The
  # webhook is account-global (keyed to the API key), so registering inside the
  # transaction is safe — a later rollback only leaves a benign extra setting.
  before_save :verify_remote_api_key, if: :will_save_change_to_api_key_encrypted?
  after_save :register_event_webhook, if: :saved_change_to_api_key_encrypted?

  def name
    'SendGrid'
  end

  # The API key is a SendGrid account secret, so it is stored encrypted at rest
  # (Fernet, reusing the installation encryption key) and never persisted in plaintext.
  def api_key
    return if api_key_encrypted.blank?

    decrypt_api_key(api_key_encrypted)
  end

  def api_key=(value)
    self.api_key_encrypted = value.present? ? encrypt_api_key(value.to_s) : nil
  end

  private

  def verify_remote_api_key
    Sendgrid::AdminClient.new(api_key).smoke_test!
  end

  def register_event_webhook
    url = webhook_callback_url
    unless absolute_url?(url)
      return mark_webhook_status('failed',
                                 "callback URL is not absolute (#{url.inspect}); set SENDGRID_WEBHOOK_URL or FRONTEND_URL")
    end

    Sendgrid::AdminClient.new(api_key).upsert_event_webhook!(callback_url: url)
    mark_webhook_status('active')
  rescue Sendgrid::ApiError => e
    mark_webhook_status('failed', e.message)
  end

  # update_column skips validations/callbacks on purpose: writing the status
  # through a normal save would re-fire the after_save callback and loop.
  def mark_webhook_status(status, error = nil)
    Rails.logger.error("Channel::Sendgrid#register_event_webhook: #{error}") if error
    update_column(:webhook_registration_status, status) # rubocop:disable Rails/SkipsModelValidations
  end

  def webhook_callback_url
    ENV.fetch('SENDGRID_WEBHOOK_URL') { "#{ENV.fetch('FRONTEND_URL', '')}/webhooks/sendgrid" }
  end

  def absolute_url?(url)
    uri = URI.parse(url.to_s)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  def encrypt_api_key(value)
    Fernet.generate(InstallationConfig.encryption_key, value)
  end

  def decrypt_api_key(token)
    verifier = Fernet.verifier(InstallationConfig.encryption_key, token, enforce_ttl: false)
    verifier.valid? ? verifier.message : nil
  rescue StandardError => e
    Rails.logger.error "Channel::Sendgrid#api_key: failed to decrypt: #{e.message}"
    nil
  end
end
