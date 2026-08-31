# frozen_string_literal: true

# Marks the local Channel as inactive when the Hub reports the underlying
# Meta connection went away (admin removed the channel at the Hub, token
# revoked at Meta, etc).
module EvolutionHub
  class ChannelDisconnectedHandler
    include ConnectionBroadcast

    def initialize(payload)
      @payload = payload
    end

    def perform
      record = find_local_channel
      unless record
        Rails.logger.warn(
          "EvolutionHub::ChannelDisconnected: no local channel found " \
          "(external_id=#{external_id.inspect} channel_id=#{hub_channel_id.inspect})"
        )
        return
      end

      mark_inactive(record)

      Rails.logger.info("EvolutionHub::ChannelDisconnected: #{record.class.name}##{record.id} marked inactive")
      broadcast_connection_change(record, ConnectionBroadcast::DISCONNECTED)
    end

    private

    def mark_inactive(record)
      if record.is_a?(Channel::Whatsapp)
        provider_config = (record.provider_config || {}).deep_dup
        hub_block = provider_config['evolution_hub'] || {}
        hub_block['status'] = 'inactive'
        provider_config['evolution_hub'] = hub_block
        record.update!(provider_config: provider_config)
      else
        hub_meta = (record.evolution_hub_meta || {}).merge('status' => 'inactive')
        record.update!(evolution_hub_meta: hub_meta)
      end
    end

    def hub_managed?(record)
      if record.is_a?(Channel::Whatsapp)
        record.provider_config.is_a?(Hash) && record.provider_config['evolution_hub'].is_a?(Hash)
      else
        record.evolution_hub_meta.is_a?(Hash) && record.evolution_hub_meta['status'].present?
      end
    end

    def external_id
      (@payload['external_id'] || @payload.dig('channel', 'external_id')).to_s
    end

    def hub_channel_id
      (@payload['channel_id'] || @payload.dig('channel', 'id')).to_s
    end

    # Mesma lógica do ChannelConnectedHandler: tenta por external_id (create
    # new) e cai pro hub channel_id (link existing).
    def find_local_channel
      by_external_id || by_hub_channel_id
    end

    # Unlike ChannelConnectedHandler, the id alone is not enough here: a
    # disconnect only speaks for a channel the Hub already manages, and marking
    # a local one would take it out of credential probing for good.
    def by_external_id
      return nil if external_id.blank?

      [Channel::Whatsapp, Channel::FacebookPage, Channel::Instagram].each do |klass|
        record = klass.find_by(id: external_id)
        return record if record && hub_managed?(record)
      end

      nil
    end

    def by_hub_channel_id
      return nil if hub_channel_id.blank?

      Channel::Whatsapp.where("provider_config -> 'evolution_hub' ->> 'channel_id' = ?", hub_channel_id).first ||
        Channel::FacebookPage.where("evolution_hub_meta ->> 'channel_id' = ?", hub_channel_id).first ||
        Channel::Instagram.where("evolution_hub_meta ->> 'channel_id' = ?", hub_channel_id).first
    end
  end
end
