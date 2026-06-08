# == Schema Information
#
# Table name: channel_sendgrid
#
#  id                :uuid             not null, primary key
#  api_key_encrypted :text             not null
#  from_email        :string           not null
#  from_name         :string
#  reply_to          :string
#  sender_domain     :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#
#  index_channel_sendgrid_on_from_email  (from_email)
#

class Channel::Sendgrid < ApplicationRecord
  include Channelable

  self.table_name = 'channel_sendgrid'

  EDITABLE_ATTRS = [:api_key, :from_email, :from_name, :reply_to, :sender_domain].freeze

  DOMAIN_FORMAT = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/i

  validates :api_key, presence: true
  validates :from_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :reply_to, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :sender_domain, format: { with: DOMAIN_FORMAT }, allow_blank: true

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
