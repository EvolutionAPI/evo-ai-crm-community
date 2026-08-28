# frozen_string_literal: true

# Fonte ÚNICA da lógica de reconciliação de credenciais de canal EvoHub (WhatsApp/FB/IG).
#
# Usado por DOIS caminhos:
#   1. ChannelConnectedHandler — ao receber o webhook channel_connected (ativação).
#   2. Auto-heal lazy — quando um canal é TOCADO (envio/publicação) e está degradado
#      (status != 'active' ou sem channel_token), reconcilia on-the-fly consultando o Hub.
#
# Por que centralizar: a lógica de "preservar channel_token, ler instagram_connection/
# facebook_connection, injetar placeholder no IG, puxar id real via get_channel" estava se
# duplicando entre handler e heal — credential-drift entre cópias é a classe de bug mais cara
# aqui. Uma cópia só.
#
# `attrs` é o hash de credenciais (do payload do webhook OU do get_channel do Hub):
#   { 'channel_token', 'access_token', 'instagram_user_id', 'page_id', 'page_access_token' }
# Qualquer chave ausente é PRESERVADA do que já existe (nunca sobrescreve com nil).
module EvolutionHub
  class ChannelReconciler
    PLACEHOLDER_PREFIX = 'hub-managed-'

    # Reconcilia o canal a partir de `attrs` (já normalizado) marcando 'active'. Salva. Retorna o channel.
    def self.apply(channel, attrs)
      new(channel, attrs).apply
    end

    # Busca as credenciais ATUAIS no Hub (GET /channels/:id) e reconcilia. Best-effort:
    # retorna false se não der p/ buscar (sem hub_channel_id ou erro de rede), sem levantar.
    def self.heal_from_hub(channel)
      hub_cid = hub_channel_id_of(channel)
      return false if hub_cid.blank?

      resp = ::EvolutionHub::Client.new.get_channel(hub_cid)
      body = resp.is_a?(Hash) ? (resp['channel'] || resp) : {}
      apply(channel, attrs_from_hub_body(body))
      true
    rescue StandardError => e
      Rails.logger.warn("EvolutionHub::ChannelReconciler heal_from_hub falhou (#{e.class}: #{e.message})")
      false
    end

    # Extrai o hash de credenciais normalizado do corpo do get_channel do Hub (por-canal:
    # facebook_connection / instagram_connection). channel_token vem na raiz (`token`).
    def self.attrs_from_hub_body(body)
      fb = body['facebook_connection'] || {}
      ig = body['instagram_connection'] || {}
      {
        'channel_token' => body['token'],
        'access_token' => ig['access_token'],
        'instagram_user_id' => ig['instagram_user_id'].presence || ig['instagram_id'],
        'page_id' => fb['page_id'],
        'page_access_token' => fb['page_access_token']
      }.compact
    end

    def self.hub_channel_id_of(channel)
      if channel.is_a?(::Channel::Whatsapp)
        channel.provider_config&.dig('evolution_hub', 'channel_id')
      else
        (channel.evolution_hub_meta || {})['channel_id']
      end.presence
    end

    # Only these three carry Hub state: `evolution_hub_meta` is a column on
    # channel_facebook_pages / channel_instagram only. Unlike hub_channel_id_of,
    # this one receives an arbitrary inbox channel, so an else-branch would
    # NoMethodError into a 500 where the caller wants a plain "no hub channel".
    def self.hub_channel_token_of(channel)
      case channel
      when ::Channel::Whatsapp
        channel.provider_config&.dig('evolution_hub', 'channel_token')
      when ::Channel::FacebookPage, ::Channel::Instagram
        (channel.evolution_hub_meta || {})['channel_token']
      end.presence
    end

    def initialize(channel, attrs)
      @channel = channel
      @attrs = attrs || {}
    end

    def apply
      case @channel
      when ::Channel::Whatsapp     then apply_whatsapp
      when ::Channel::FacebookPage then apply_facebook
      when ::Channel::Instagram    then apply_instagram
      end
      @channel.save!
      @channel
    end

    private

    # PRESERVA channel_token/status no evolution_hub_meta (nunca sobrescreve com nil).
    def active_hub_meta
      existing = @channel.evolution_hub_meta || {}
      existing.merge(
        'channel_id' => @attrs['channel_id'].presence || existing['channel_id'],
        'channel_token' => @attrs['channel_token'].presence || existing['channel_token'],
        'status' => 'active'
      )
    end

    def apply_whatsapp
      pc = (@channel.provider_config || {}).deep_dup
      pc['api_key'] = @attrs['access_token'] if @attrs['access_token'].present?
      hub = pc['evolution_hub'] || {}
      hub.merge!(
        'channel_id' => @attrs['channel_id'].presence || hub['channel_id'],
        'channel_token' => @attrs['channel_token'].presence || hub['channel_token'],
        'status' => 'active'
      )
      pc['evolution_hub'] = hub
      @channel.provider_config = pc
    end

    def apply_facebook
      @channel.page_access_token = @attrs['page_access_token'].presence || @channel.page_access_token
      @channel.page_id = @attrs['page_id'] if @channel.read_attribute(:page_id).blank? && @attrs['page_id'].present?
      @channel.evolution_hub_meta = active_hub_meta
    end

    def apply_instagram
      @channel.access_token = @attrs['access_token'] if @attrs['access_token'].present?
      @channel.instagram_id = @attrs['instagram_user_id'] if @channel.instagram_id.blank? && @attrs['instagram_user_id'].present?
      # presence guards (IG valida access_token/instagram_id unless hub_pending?). read_attribute:
      # o getter access_token é sobrescrito (RefreshOauthTokenService) e clobraria o token novo.
      @channel.access_token = "#{PLACEHOLDER_PREFIX}#{SecureRandom.hex(8)}" if @channel.read_attribute(:access_token).blank?
      @channel.instagram_id = "pending_#{SecureRandom.hex(6)}" if @channel.instagram_id.blank?
      @channel.evolution_hub_meta = active_hub_meta
    end
  end
end
