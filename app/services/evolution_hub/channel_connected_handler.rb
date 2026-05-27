# frozen_string_literal: true

# Handles `channel_connected` lifecycle webhooks from the Evolution Hub.
#
# The Hub posts this event after the end user finishes the OAuth flow at the
# public connect link. The payload carries the Meta credentials (phone_number_id
# / page_id / instagram_user_id + access_token) we need to mark the local
# Channel record as fully connected.
module EvolutionHub
  class ChannelConnectedHandler
    def initialize(payload)
      @payload = payload
    end

    def perform
      channel = find_local_channel
      unless channel
        Rails.logger.warn("EvolutionHub::ChannelConnected: no local channel found for external_id=#{external_id.inspect}")
        return
      end

      Rails.logger.info("EvolutionHub::ChannelConnected: activating #{channel.class.name}##{channel.id} (meta_connection present=#{meta.any?})")

      case channel
      when Channel::Whatsapp     then mark_whatsapp_connected(channel)
      when Channel::FacebookPage then mark_facebook_connected(channel)
      when Channel::Instagram    then mark_instagram_connected(channel)
      else
        Rails.logger.warn("EvolutionHub::ChannelConnected: unsupported channel class #{channel.class}")
      end
    end

    private

    attr_reader :payload

    def external_id
      # O Hub envia external_id em duas posições possíveis:
      #   - top-level payload['external_id'] (shape lifecycle direto)
      #   - payload['channel']['external_id'] (shape com objeto Channel embedded)
      # Aceita ambos pra robustez contra mudanças de schema do Hub.
      (payload['external_id'] || payload.dig('channel', 'external_id')).to_s
    end

    def meta
      payload['meta_connection'] || {}
    end

    def find_local_channel
      return nil if external_id.blank?
      # external_id maps to the local Channel's UUID-as-string.
      [Channel::Whatsapp, Channel::FacebookPage, Channel::Instagram].each do |klass|
        record = klass.find_by(id: external_id)
        return record if record
      end
      nil
    end

    def mark_whatsapp_connected(channel)
      provider_config = (channel.provider_config || {}).deep_dup
      provider_config['api_key']             = meta['access_token'] if meta['access_token'].present?
      provider_config['phone_number_id']     = meta['phone_number_id'] if meta['phone_number_id'].present?
      provider_config['waba_id']             = meta['waba_id'] if meta['waba_id'].present?
      provider_config['business_account_id'] = meta['waba_id'] if meta['waba_id'].present?
      hub_block = provider_config['evolution_hub'] || {}
      hub_block.merge!(
        'channel_id'    => payload['channel_id'],
        'channel_token' => payload['channel_token'],
        'status'        => 'active'
      )
      provider_config['evolution_hub'] = hub_block

      channel.update!(provider_config: provider_config)
      mark_inbox_active(channel)
    end

    def mark_facebook_connected(channel)
      channel.page_access_token = meta['access_token'] if meta['access_token'].present?
      channel.evolution_hub_meta = (channel.evolution_hub_meta || {}).merge(
        'channel_id'    => payload['channel_id'],
        'channel_token' => payload['channel_token'],
        'status'        => 'active'
      )
      channel.save!
      mark_inbox_active(channel)
    end

    def mark_instagram_connected(channel)
      channel.access_token = meta['access_token'] if meta['access_token'].present?
      channel.instagram_id = meta['instagram_user_id'] if meta['instagram_user_id'].present?
      channel.evolution_hub_meta = (channel.evolution_hub_meta || {}).merge(
        'channel_id'    => payload['channel_id'],
        'channel_token' => payload['channel_token'],
        'status'        => 'active'
      )
      channel.save!
      mark_inbox_active(channel)
    end

    def mark_inbox_active(channel)
      inbox = channel.inbox
      return unless inbox
      inbox.update!(enable_auto_assignment: true) if inbox.respond_to?(:enable_auto_assignment)
    end
  end
end
