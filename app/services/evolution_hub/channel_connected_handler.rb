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
      # Primária: external_id == UUID do Channel local (caso 'create new' do
      # InboxBuilder, onde o CRM seta external_id no POST /channels).
      if external_id.present?
        [Channel::Whatsapp, Channel::FacebookPage, Channel::Instagram].each do |klass|
          record = klass.find_by(id: external_id)
          return record if record
        end
      end

      # Fallback: external_id vazio (caso 'link existing' — UpdateChannel do
      # Hub só aceita 'name', não dá pra setar external_id depois). Acha
      # pelo hub channel_id armazenado em provider_config / evolution_hub_meta.
      hub_channel_id = (payload['channel_id'] || payload.dig('channel', 'id')).to_s
      return nil if hub_channel_id.blank?

      Channel::Whatsapp.where("provider_config -> 'evolution_hub' ->> 'channel_id' = ?", hub_channel_id).first ||
        Channel::FacebookPage.where("evolution_hub_meta ->> 'channel_id' = ?", hub_channel_id).first ||
        Channel::Instagram.where("evolution_hub_meta ->> 'channel_id' = ?", hub_channel_id).first
    end

    def mark_whatsapp_connected(channel)
      provider_config = (channel.provider_config || {}).deep_dup
      provider_config['api_key']             = meta['access_token'] if meta['access_token'].present?
      provider_config['phone_number_id']     = meta['phone_number_id'] if meta['phone_number_id'].present?
      provider_config['waba_id']             = meta['waba_id'] if meta['waba_id'].present?
      provider_config['business_account_id'] = meta['waba_id'] if meta['waba_id'].present?
      hub_block = provider_config['evolution_hub'] || {}
      hub_block.merge!(
        'channel_id'    => payload['channel_id'].presence    || hub_block['channel_id'],
        'channel_token' => payload['channel_token'].presence || hub_block['channel_token'],
        'status'        => 'active'
      )
      provider_config['evolution_hub'] = hub_block

      channel.update!(provider_config: provider_config)
      mark_inbox_active(channel)
      enqueue_template_sync(channel)
    end

    # The Channel::Whatsapp `after_create :sync_templates` callback runs while
    # provider_config still lacks credentials (the Hub fills them later via
    # this webhook), so the initial sync fetches nothing. Re-trigger here once
    # credentials are in place so `message_templates` is populated without a
    # manual sync.
    #
    # Requires waba_id + at least one token. `WhatsappCloudService#sync_templates`
    # picks the auth strategy: Hub mode → Bearer header (channel_token or api_key
    # fallback); non-Hub → `?access_token=` query param (needs api_key).
    def enqueue_template_sync(channel)
      waba_id = channel.provider_config['waba_id'].presence ||
                channel.provider_config['business_account_id'].presence
      api_key = channel.provider_config['api_key'].presence
      channel_token = channel.provider_config.dig('evolution_hub', 'channel_token').presence
      if waba_id.blank? || (api_key.blank? && channel_token.blank?)
        Rails.logger.warn(
          "EvolutionHub::ChannelConnected: skipping template sync for Channel::Whatsapp##{channel.id} " \
          "(waba_id_present=#{waba_id.present?} api_key_present=#{api_key.present?} channel_token_present=#{channel_token.present?})"
        )
        return
      end

      Channels::Whatsapp::TemplatesSyncJob.perform_later(channel)
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
