# frozen_string_literal: true

# Marks the local Channel as inactive when the Hub reports the underlying
# Meta connection went away (admin removed the channel at the Hub, token
# revoked at Meta, etc).
module EvolutionHub
  class ChannelDisconnectedHandler
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

      Rails.logger.info("EvolutionHub::ChannelDisconnected: #{record.class.name}##{record.id} marked inactive")
    end

    private

    def external_id
      (@payload['external_id'] || @payload.dig('channel', 'external_id')).to_s
    end

    def hub_channel_id
      (@payload['channel_id'] || @payload.dig('channel', 'id')).to_s
    end

    # Mesma lógica do ChannelConnectedHandler: tenta por external_id (create
    # new) e cai pro hub channel_id (link existing).
    def find_local_channel
      if external_id.present?
        [Channel::Whatsapp, Channel::FacebookPage, Channel::Instagram].each do |klass|
          record = klass.find_by(id: external_id)
          return record if record
        end
      end

      return nil if hub_channel_id.blank?

      Channel::Whatsapp.where("provider_config -> 'evolution_hub' ->> 'channel_id' = ?", hub_channel_id).first ||
        Channel::FacebookPage.where("evolution_hub_meta ->> 'channel_id' = ?", hub_channel_id).first ||
        Channel::Instagram.where("evolution_hub_meta ->> 'channel_id' = ?", hub_channel_id).first
    end
  end
end
