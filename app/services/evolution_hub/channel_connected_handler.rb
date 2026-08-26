# frozen_string_literal: true

# Handles `channel_connected` lifecycle webhooks from the Evolution Hub.
#
# The Hub posts this event after the end user finishes the OAuth flow at the
# public connect link. The payload carries the Meta credentials (phone_number_id
# / page_id / instagram_user_id + access_token) we need to mark the local
# Channel record as fully connected.
module EvolutionHub
  class ChannelConnectedHandler
    include ConnectionBroadcast

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
        return
      end

      broadcast_connection_change(channel, ConnectionBroadcast::CONNECTED)
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
        'channel_id' => payload['channel_id'].presence    || hub_block['channel_id'],
        'channel_token' => payload['channel_token'].presence || hub_block['channel_token'],
        'status' => 'active'
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
      # O Hub guarda as creds do FB em `facebook_connection` (não em `meta_connection`); o payload
      # do channel_connected inclui essa chave. Lê page_id/page_access_token dela. Preserva o que
      # já existe se o payload omitir (nunca sobrescreve com nil — igual mark_whatsapp_connected).
      fb = payload['facebook_connection'] || {}
      channel.page_access_token = meta['access_token'].presence || fb['page_access_token'].presence || channel.page_access_token
      channel.page_id = fb['page_id'] if channel.read_attribute(:page_id).blank? && fb['page_id'].present?
      channel.evolution_hub_meta = active_hub_meta(channel)
      channel.save!
      mark_inbox_active(channel)
    end

    def mark_instagram_connected(channel)
      # O Hub guarda as creds do IG em `instagram_connection`; o payload inclui essa chave. Sem o
      # instagram_id REAL a publicação/insights do IG quebram (é o {ig-id} da Graph API).
      ig = payload['instagram_connection'] || {}
      token = meta['access_token'].presence || ig['access_token'].presence
      channel.access_token = token if token
      if channel.instagram_id.blank?
        channel.instagram_id = meta['instagram_user_id'].presence || ig['instagram_user_id'].presence || ig['instagram_id'].presence
      end
      # Fallback (Hub antigo, sem a chave no payload): busca o id real via GET /channels/:id.
      channel.instagram_id = real_instagram_id_from_hub(channel) if channel.instagram_id.blank?
      ensure_instagram_presence(channel)
      channel.evolution_hub_meta = active_hub_meta(channel)
      channel.save!
      mark_inbox_active(channel)
    end

    # Merge do evolution_hub_meta marcando 'active' e PRESERVANDO channel_id/channel_token
    # (`.presence || existente`, igual mark_whatsapp_connected) — nunca sobrescreve com nil
    # quando o Hub omite o token no lifecycle. Compartilhado por IG e FB.
    def active_hub_meta(channel)
      existing = channel.evolution_hub_meta || {}
      existing.merge(
        'channel_id' => payload['channel_id'].presence    || existing['channel_id'],
        'channel_token' => payload['channel_token'].presence || existing['channel_token'],
        'status' => 'active'
      )
    end

    # IG valida `access_token`/`instagram_id` presence ao virar 'active'. Se o Hub não mandou o
    # access_token (trafega via channel_token/proxy), injeta placeholder p/ não dar RecordInvalid.
    # ⚠️ read_attribute: o getter `access_token` é sobrescrito (RefreshOauthTokenService) e
    # retorna nil quando expires_at blank — usar o getter clobraria o token recém-setado.
    def ensure_instagram_presence(channel)
      channel.access_token = "hub-managed-#{SecureRandom.hex(8)}" if channel.read_attribute(:access_token).blank?
      channel.instagram_id = "pending_#{SecureRandom.hex(6)}" if channel.instagram_id.blank?
    end

    # Busca o instagram_user_id REAL no Hub (GET /channels/:id → instagram_connection) quando o
    # webhook não o trouxe. Best-effort: nil em qualquer erro (cai no placeholder). Não loga token.
    def real_instagram_id_from_hub(channel)
      hub_cid = (channel.evolution_hub_meta || {})['channel_id'].presence || payload['channel_id'].presence
      return nil if hub_cid.blank?

      resp = EvolutionHub::Client.new.get_channel(hub_cid)
      body = resp.is_a?(Hash) ? (resp['channel'] || resp) : {}
      ig = body['instagram_connection'] || {}
      ig['instagram_user_id'].presence || ig['instagram_id'].presence
    rescue StandardError => e
      Rails.logger.warn("EvolutionHub::ChannelConnected: get_channel falhou p/ ig real id (#{e.class}: #{e.message})")
      nil
    end

    def mark_inbox_active(channel)
      # Reconectar SEMPRE limpa o flag de reautorização (Reauthorizable, em Redis).
      # Sem isto, um canal que já tropeçou em 190 (ex.: a DM batia no Graph com o
      # channel_token opaco antes do fix) fica preso em reauthorization_required? e
      # o MessageBuilder#perform engole TODA DM futura — mesmo após reconectar. O
      # channel_connected é o ponto natural pra zerar (o operador acabou de refazer o
      # OAuth no Hub). reauthorized! limpa o count + o flag.
      channel.reauthorized! if channel.respond_to?(:reauthorized!)

      inbox = channel.inbox
      return unless inbox

      inbox.update!(enable_auto_assignment: true) if inbox.respond_to?(:enable_auto_assignment)
    end
  end
end
