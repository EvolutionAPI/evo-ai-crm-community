# == Schema Information
#
# Table name: channel_whatsapp
#
#  id                  :uuid             not null, primary key
#  phone_number        :string           not null
#  provider            :string           default("default")
#  provider_config     :jsonb
#  provider_connection :jsonb
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
# Indexes
#
#  index_channel_whatsapp_on_phone_number  (phone_number) UNIQUE
#

class Channel::Whatsapp < ApplicationRecord
  include Channelable
  include Reauthorizable
  include EvolutionHubReconcilable
  include ChannelMessageTemplates
  include EvolutionHubChannelCleanup

  self.table_name = 'channel_whatsapp'
  EDITABLE_ATTRS = [:phone_number, :provider, { provider_config: {} }].freeze

  # default at the moment is 360dialog lets change later.
  PROVIDERS = %w[default whatsapp_cloud baileys evolution evolution_go notificame zapi].freeze
  before_validation :ensure_webhook_verify_token
  before_validation :merge_evolution_go_global_config, if: -> { provider == 'evolution_go' }

  validates :provider, inclusion: { in: PROVIDERS }
  validates :phone_number, presence: true, uniqueness: true
  validate :validate_provider_config

  has_one :inbox, as: :channel, dependent: :destroy

  after_create_commit :subscribe
  # Re-subscribe to webhooks when credentials change (e.g. WhatsApp Cloud
  # reconnect updates api_key / phone_number_id / waba_id). Without this,
  # provider_config is updated in the DB but Meta never gets a new
  # subscribed_apps call, so the number stays disconnected from webhooks.
  after_update_commit :subscribe,
                      if: -> { provider == 'whatsapp_cloud' && saved_change_to_provider_config? }
  after_create :sync_templates
  before_destroy :unsubscribe

  before_destroy :disconnect_channel_provider, if: -> { provider.in?(%w[baileys evolution evolution_go]) }

  # Notificame specific callbacks
  after_create_commit -> { Notificame::SubscribeWebhookJob.perform_later(id) },
                      if: -> { provider == 'notificame' }
  after_update_commit -> { Notificame::SubscribeWebhookJob.perform_later(id) },
                      if: -> { provider == 'notificame' && saved_change_to_provider_config? }
  after_destroy_commit -> { provider_service.unsubscribe_from_webhooks },
                       if: -> { provider == 'notificame' }

  # Z-API specific callbacks - configure webhooks after channel creation
  after_create_commit -> { provider_service.subscribe_to_webhooks },
                      if: -> { provider == 'zapi' }
  after_destroy_commit -> { provider_service.unsubscribe_from_webhooks },
                       if: -> { provider == 'zapi' }

  def name
    'Whatsapp'
  end

  def provider_service
    case provider
    when 'whatsapp_cloud'
      Whatsapp::Providers::WhatsappCloudService.new(whatsapp_channel: self)
    when 'baileys'
      Whatsapp::Providers::WhatsappBaileysService.new(whatsapp_channel: self)
    when 'evolution'
      Whatsapp::Providers::EvolutionService.new(whatsapp_channel: self)
    when 'evolution_go'
      Whatsapp::Providers::EvolutionGoService.new(whatsapp_channel: self)
    when 'notificame'
      Whatsapp::Providers::NotificameService.new(whatsapp_channel: self)
    when 'zapi'
      Whatsapp::Providers::ZapiService.new(whatsapp_channel: self)
    else
      Whatsapp::Providers::Whatsapp360DialogService.new(whatsapp_channel: self)
    end
  end

  # Propagates an agent's message deletion to the provider (delete-for-everyone),
  # where supported. Returns false (CRM-only) for providers without delete_message.
  def delete_message(message)
    service = provider_service
    return false unless service.respond_to?(:delete_message)

    service.delete_message(message)
  rescue StandardError => e
    Rails.logger.error("Channel::Whatsapp#delete_message failed: #{e.message}")
    false
  end

  def use_internal_host?
    provider == 'baileys' && ENV.fetch('BAILEYS_PROVIDER_USE_INTERNAL_HOST_URL', false)
  end

  def mark_message_templates_updated
    # No-op: templates are now tracked via message_templates table updated_at timestamps
    # This method is kept for backward compatibility but does nothing
  end

  def update_provider_connection!(provider_connection)
    assign_attributes(provider_connection: provider_connection)
    # NOTE: Skip `validate_provider_config?` check
    save!(validate: false)
  end

  def provider_connection_data
    data = { connection: provider_connection['connection'] }
    if Current.user&.role == 'administrator'
      data[:qr_data_url] = provider_connection['qr_data_url']
      data[:error] = provider_connection['error']
    end
    data
  end

  def toggle_typing_status(typing_status, conversation:)
    return unless provider_service.respond_to?(:toggle_typing_status)

    provider_service.toggle_typing_status(conversation.contact.phone_number, typing_status)
  end

  def update_presence(status)
    return unless provider_service.respond_to?(:update_presence)

    provider_service.update_presence(status)
  end

  def read_messages(messages, conversation:)
    return unless provider_service.respond_to?(:read_messages)
    # NOTE: This is the default behavior, so `mark_as_read` being `nil` is the same as `true`.
    return if provider_config&.dig('mark_as_read') == false

    provider_service.read_messages(conversation.contact.phone_number, messages)
  end

  def unread_conversation(conversation)
    return unless provider_service.respond_to?(:unread_message)

    # NOTE: For the Baileys provider, the last message is required even if it is an outgoing message.
    last_message = conversation.messages.last
    provider_service.unread_message(conversation.contact.phone_number, last_message) if last_message
  end

  def disconnect_channel_provider
    provider_service.disconnect_channel_provider
  end

  def received_messages(messages, conversation)
    return unless provider_service.respond_to?(:received_messages)

    provider_service.received_messages(conversation.contact.phone_number, messages)
  end

  delegate :setup_channel_provider, to: :provider_service
  delegate :send_message, to: :provider_service
  delegate :send_template, to: :provider_service
  delegate :sync_templates, to: :provider_service
  delegate :media_url, to: :provider_service
  delegate :api_headers, to: :provider_service
  delegate :subscribe_to_webhooks, to: :provider_service
  delegate :unsubscribe_from_webhooks, to: :provider_service
  delegate :create_template, to: :provider_service
  delegate :update_template, to: :provider_service
  delegate :delete_template, to: :provider_service

  def subscribe
    return unless provider == 'whatsapp_cloud'
    # In Hub mode the Hub already subscribed the WABA on its side using the
    # real Meta app token. The CRM doesn't hold that token and doesn't need
    # to re-subscribe — webhooks reach us via the Hub's relay.
    return if MetaBaseUrl.enabled?
    return unless provider_config['waba_id'].present? && provider_config['api_key'].present?

    # ref https://developers.facebook.com/docs/whatsapp/business-platform/webhooks#subscription
    HTTParty.post(
      "https://graph.facebook.com/v23.0/#{provider_config['waba_id']}/subscribed_apps",
      headers: {
        'Authorization' => "Bearer #{provider_config['api_key']}",
        'Content-Type' => 'application/json'
      }
    )
    Rails.logger.info "WhatsApp subscribed_apps: Successfully subscribed WABA #{provider_config['waba_id']}"
  rescue StandardError => e
    Rails.logger.error "WhatsApp subscribed_apps error: #{e.inspect}"
    true
  end

  def unsubscribe
    return unless provider == 'whatsapp_cloud'
    return if MetaBaseUrl.enabled?
    return unless provider_config['waba_id'].present? && provider_config['api_key'].present?

    HTTParty.delete(
      "https://graph.facebook.com/v23.0/#{provider_config['waba_id']}/subscribed_apps",
      headers: {
        'Authorization' => "Bearer #{provider_config['api_key']}",
        'Content-Type' => 'application/json'
      }
    )
    Rails.logger.info "WhatsApp subscribed_apps: Successfully unsubscribed WABA #{provider_config['waba_id']}"
  rescue StandardError => e
    Rails.logger.error "WhatsApp unsubscribed_apps error: #{e.inspect}"
    true
  end

  private

  def ensure_webhook_verify_token
    provider_config['webhook_verify_token'] ||= SecureRandom.hex(16) if provider.in?(%w[whatsapp_cloud baileys notificame])
  end

  def merge_evolution_go_global_config
    self.provider_config ||= {}
    if provider_config['api_url'].blank?
      global_url = GlobalConfigService.load('EVOLUTION_GO_API_URL', '').to_s.strip
      provider_config['api_url'] = global_url if global_url.present?
    end
    if provider_config['admin_token'].blank?
      global_token = GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', '').to_s.strip
      provider_config['admin_token'] = global_token if global_token.present?
    end
  end

  def validate_provider_config
    # Skip credential validation while the Hub-relayed flow is still pending —
    # the access_token and phone_number_id are only filled in by the Hub
    # `channel.connected` webhook, after the operator finishes Meta OAuth.
    return if hub_pending?
    # In Hub mode we authenticate Meta calls with the Hub channel_token (the
    # Hub swaps it for the Meta access_token internally), so the local
    # `api_key` is intentionally empty and the validator's "Bearer api_key"
    # health check would fail. Trust the Hub's connect lifecycle here.
    return if hub_active?

    errors.add(:provider_config, 'Invalid Credentials') unless provider_service.validate_provider_config?
  end

  def hub_pending?
    provider_config.is_a?(Hash) && provider_config.dig('evolution_hub', 'status') == 'pending'
  end

  def hub_active?
    provider_config.is_a?(Hash) && provider_config.dig('evolution_hub', 'status') == 'active'
  end
end
