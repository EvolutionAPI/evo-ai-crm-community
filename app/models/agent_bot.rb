# == Schema Information
#
# Table name: agent_bots
#
#  id                         :uuid             not null, primary key
#  api_key                    :string
#  bot_config                 :jsonb
#  bot_provider               :string           default("webhook_provider"), not null
#  bot_type                   :integer          default("webhook")
#  debounce_time              :integer          default(5), not null
#  delay_per_character        :decimal(8, 2)    default(50.0)
#  description                :string
#  message_signature          :text
#  name                       :string
#  outgoing_url               :string
#  text_segmentation_enabled  :boolean          default(FALSE), not null
#  text_segmentation_limit    :integer          default(300)
#  text_segmentation_min_size :integer          default(50)
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#
class AgentBot < ApplicationRecord
  include AccessTokenable
  include Avatarable

  has_many :agent_bot_inboxes, dependent: :destroy_async
  has_many :inboxes, through: :agent_bot_inboxes
  has_many :messages, as: :sender, dependent: :nullify

  before_destroy :cleanup_associations
  enum :bot_type, { webhook: 0 }
  enum :bot_provider, { webhook_provider: 'webhook', evo_ai_provider: 'evo_ai', n8n_provider: 'n8n' }

  validates :outgoing_url, length: { maximum: Limits::URL_LENGTH_LIMIT }
  validates :api_key, length: { maximum: 1000 }, allow_blank: true
  validates :api_key, presence: true, if: :evo_ai_provider?
  # N8n can optionally use basic auth, so api_key is not required
  validates :debounce_time, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 60 }

  def available_name
    name
  end

  def push_event_data(inbox = nil)
    {
      id: id,
      name: name,
      avatar_url: avatar_url || inbox&.avatar_url,
      type: 'agent_bot'
    }
  end

  # ⚠️ NO api_key here, on purpose (EVO-2250 story 2.4).
  #
  # This hash reaches `Message#webhook_data` when a bot is the sender, and the
  # webhook listener delivers that payload to URLs the CUSTOMER registered. The
  # bot secret was travelling to third-party endpoints. It is not needed there:
  # the bot's own dispatch reads the credential through
  # AgentBots::CredentialResolution.
  def webhook_data
    {
      id: id,
      name: name,
      type: 'agent_bot',
      outgoing_url: outgoing_url
    }
  end

  def safe_destroy
    Rails.logger.info "Starting safe destroy for AgentBot #{id}"

    # Remove from inboxes first
    agent_bot_inboxes.destroy_all

    # Nullify messages
    messages.update_all(sender_id: nil, sender_type: nil)

    # Remove avatar if attached
    avatar.purge if avatar.attached?

    # Finally destroy the bot
    destroy
  rescue StandardError => e
    Rails.logger.error "Error in safe_destroy for AgentBot #{id}: #{e.message}"
    false
  end

  private

  def cleanup_associations
    Rails.logger.info "Cleaning up associations for AgentBot #{id}"

    # Cleanup agent bot inboxes synchronously to avoid dependency issues
    agent_bot_inboxes.destroy_all

    # Nullify messages asynchronously (they're already set to dependent: :nullify)
    Rails.logger.info "AgentBot #{id} cleanup completed"
  rescue StandardError => e
    Rails.logger.error "Error cleaning up AgentBot #{id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    # Don't halt destruction, just log the error
  end
end
