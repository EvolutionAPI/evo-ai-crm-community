# frozen_string_literal: true

# Source of truth for which config keys are required for each integration.
# Consumed by Api::V1::Admin::AppConfigsController (save-time enforcement)
# and Api::V1::GlobalConfigController (public `hasXxxConfig` booleans used
# by the channel creation UI). Keeping both in sync from a single map avoids
# drift between "the backend accepts the save" and "the frontend enables the tile".
module IntegrationRequirements
  CONFIG_TYPE_REQUIRED_KEYS = {
    'facebook'     => %w[FB_APP_ID FB_APP_SECRET FB_VERIFY_TOKEN],
    'whatsapp'     => %w[WP_APP_ID WP_APP_SECRET WP_VERIFY_TOKEN WP_WHATSAPP_CONFIG_ID],
    'instagram'    => %w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET INSTAGRAM_VERIFY_TOKEN],
    'evolution'    => %w[EVOLUTION_API_URL EVOLUTION_ADMIN_SECRET],
    'evolution_go' => %w[EVOLUTION_GO_API_URL EVOLUTION_GO_ADMIN_SECRET],
    'evolution_hub' => %w[EVOLUTION_HUB_API_KEY EVOLUTION_HUB_WEBHOOK_SECRET],
    'twitter'      => %w[TWITTER_APP_ID TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET TWITTER_ENVIRONMENT]
  }.freeze

  def self.required_keys(config_type)
    CONFIG_TYPE_REQUIRED_KEYS.fetch(config_type.to_s, [].freeze)
  end

  def self.configured?(config_type)
    keys = required_keys(config_type)
    return false if keys.empty?

    keys.all? do |key|
      GlobalConfigService.load(key, nil).to_s.strip != ''
    end
  end
end
