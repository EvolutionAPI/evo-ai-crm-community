# frozen_string_literal: true

# Deletes the paired Hub channel when a CRM Meta channel is destroyed.
#
# Without this, deleting an Inbox (which cascades `dependent: :destroy` to the
# Channel) only removes the local record — the Hub keeps the channel and its
# webhook, the next OAuth attempt collides with a stale token, and orphan
# rows accumulate in the Hub DB.
#
# Two storage shapes are supported because the channel types disagree:
#   - Channel::Whatsapp:    provider_config['evolution_hub']['channel_id']
#   - FacebookPage/Instagram: evolution_hub_meta['channel_id']
#
# Failures are logged but NOT raised — losing the Hub side is recoverable
# (admin can purge from the Hub UI), but blocking the CRM destroy would leave
# the operator unable to delete a broken inbox.
module EvolutionHubChannelCleanup
  extend ActiveSupport::Concern

  included do
    before_destroy :evolution_hub_cleanup
  end

  private

  def evolution_hub_cleanup
    hub_channel_id = extract_hub_metadata('channel_id')
    hub_webhook_id = extract_hub_metadata('webhook_id')
    linked         = extract_hub_metadata('linked') == true
    return if hub_channel_id.blank? && hub_webhook_id.blank?

    client = EvolutionHub::Client.new

    # Order matters: delete the webhook FIRST. If we deleted the channel first
    # and then the webhook call failed, the dashboard would show an orphan
    # webhook pointing to a now-deleted channel — exactly the bug we're
    # trying to avoid. Webhook delete is also cheaper to retry manually.
    if hub_webhook_id.present?
      client.delete_webhook(hub_webhook_id)
      Rails.logger.info("EvolutionHubChannelCleanup: deleted Hub webhook #{hub_webhook_id} for #{self.class.name}##{id}")
    end

    # Canais LINKED não são deletados do Hub — o Hub continua dono deles,
    # o CRM só consumia mensagens via webhook. Removemos só o webhook acima.
    if linked
      Rails.logger.info("EvolutionHubChannelCleanup: preserving linked Hub channel #{hub_channel_id} (#{self.class.name}##{id})")
    elsif hub_channel_id.present?
      client.delete_channel(hub_channel_id)
      Rails.logger.info("EvolutionHubChannelCleanup: deleted Hub channel #{hub_channel_id} for #{self.class.name}##{id}")
    end
  rescue EvolutionHub::Client::RequestError => e
    Rails.logger.warn(
      "EvolutionHubChannelCleanup: Hub returned #{e.status} during cleanup for #{self.class.name}##{id} — #{e.message}"
    )
  rescue EvolutionHub::Client::ConfigurationError => e
    Rails.logger.warn("EvolutionHubChannelCleanup: skipped — Hub not configured (#{e.message})")
  rescue StandardError => e
    Rails.logger.error("EvolutionHubChannelCleanup: unexpected error for #{self.class.name}##{id} — #{e.class}: #{e.message}")
  end

  # Reads a value from the channel's Hub metadata, regardless of which storage
  # shape this channel type uses. Whatsapp tucks it into provider_config; the
  # Meta channels (FacebookPage, Instagram) have a dedicated jsonb column.
  def extract_hub_metadata(key)
    if respond_to?(:provider_config) && provider_config.is_a?(Hash)
      value = provider_config.dig('evolution_hub', key)
      return value if value.present?
    end

    if respond_to?(:evolution_hub_meta) && evolution_hub_meta.is_a?(Hash)
      return evolution_hub_meta[key]
    end

    nil
  end
end
