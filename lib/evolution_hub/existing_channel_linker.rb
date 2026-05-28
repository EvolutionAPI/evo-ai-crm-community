# frozen_string_literal: true

module EvolutionHub
  # Cria um Inbox local apontando pra um canal Hub PREEXISTENTE — em vez
  # de criar um canal novo no Hub (que é o que InboxBuilder faz).
  #
  # Caso de uso: o operador já tem um canal conectado no Evo Hub (talvez
  # criado por outra integração ou pela UI do próprio Hub) e quer só
  # plugar um inbox novo do CRM nele. O Hub continua dono do canal; o CRM
  # só "aluga" um webhook pra receber eventos.
  #
  # Diferenças vs InboxBuilder:
  #   - NÃO chama POST /api/v1/channels (canal já existe)
  #   - Chama GET /api/v1/channels/:id pra puxar phone_number_id / page_id /
  #     instagram_user_id (necessários pro inbound webhook routing)
  #   - Cria webhook standalone (POST /api/v1/webhooks) já associado ao
  #     canal Hub existente (campo `channels: [...]` no body)
  #   - Marca status='active' direto (canal já está OAuth-conectado na Meta)
  #   - Marca `linked: true` no metadata pro cleanup NÃO deletar o canal
  #     do Hub quando o inbox CRM for removido
  class ExistingChannelLinker
    class UnsupportedChannelType < StandardError; end
    class ChannelTypeMismatch < StandardError; end
    class AlreadyLinked < StandardError; end

    # Mapeia o channel_type do payload do CRM pro type do Hub.
    SUPPORTED_TYPES = {
      'whatsapp_cloud' => 'whatsapp',
      'facebook_page'  => 'facebook',
      'facebook'       => 'facebook',
      'instagram'      => 'instagram'
    }.freeze

    def initialize(channel_type:, name:, hub_channel_id:)
      @channel_type = channel_type.to_s
      @name = name.to_s.presence || "#{@channel_type.humanize} via Evolution Hub"
      @hub_channel_id = hub_channel_id.to_s
    end

    def perform
      raise UnsupportedChannelType, "channel_type=#{@channel_type} cannot use Evolution Hub" \
        unless SUPPORTED_TYPES.key?(@channel_type)
      raise ArgumentError, 'hub_channel_id is required' if @hub_channel_id.blank?

      hub_channel = fetch_hub_channel
      validate_type_match!(hub_channel)
      validate_not_already_linked!

      ActiveRecord::Base.transaction do
        webhook = create_webhook_in_hub
        channel = build_local_channel(hub_channel, webhook)
        inbox = create_inbox(channel)
        { inbox: inbox, hub_channel: hub_channel }
      end
    end

    private

    def hub_client
      @hub_client ||= EvolutionHub::Client.new
    end

    def crm_webhook_url
      base = ENV.fetch('BACKEND_URL', 'http://localhost:3000')
      "#{base.chomp('/')}/webhooks/evolution_hub"
    end

    def webhook_secret
      GlobalConfigService.load('EVOLUTION_HUB_WEBHOOK_SECRET', nil)
    end

    def fetch_hub_channel
      hub_client.get_channel(@hub_channel_id)
    end

    # O dropdown do front idealmente já filtra por tipo, mas defesa em
    # profundidade: rejeita se alguém POSTar com hub_channel_id de tipo
    # diferente (whatsapp vs facebook, etc) pra evitar dados inconsistentes.
    def validate_type_match!(hub_channel)
      hub_type = hub_channel.is_a?(Hash) ? hub_channel['type'] : nil
      expected = SUPPORTED_TYPES[@channel_type]
      return if hub_type == expected

      raise ChannelTypeMismatch,
            "Hub channel type=#{hub_type.inspect} does not match channel_type=#{@channel_type.inspect}"
    end

    # Mesmo canal Hub não pode estar atrelado a 2 inboxes do CRM — senão
    # mensagens chegam duplicadas (cada Channel local vira destino do
    # mesmo webhook). O frontend filtra, mas validamos aqui também.
    def validate_not_already_linked!
      already = Channel::Whatsapp.where("provider_config -> 'evolution_hub' ->> 'channel_id' = ?", @hub_channel_id).exists?
      already ||= Channel::FacebookPage.where("evolution_hub_meta ->> 'channel_id' = ?", @hub_channel_id).exists?
      already ||= Channel::Instagram.where("evolution_hub_meta ->> 'channel_id' = ?", @hub_channel_id).exists?
      raise AlreadyLinked, "Hub channel #{@hub_channel_id} is already linked to another inbox" if already
    end

    def create_webhook_in_hub
      response = hub_client.create_webhook(
        name: "EvoCRM — #{@name}",
        url: crm_webhook_url,
        events: %w[channel_connected channel_disconnected event_received webhook_delivered webhook_failed],
        secret: webhook_secret,
        channels: [@hub_channel_id]
      )
      response.is_a?(Hash) ? response : {}
    end

    # Constrói o canal local já em 'active' (sem placeholders) puxando os
    # IDs Meta necessários do payload do GET. Estes IDs são pra inbound
    # webhook routing — o forwarded_meta_event no EvolutionHubEventsJob
    # despacha pra WhatsappEventsJob/FacebookEventsJob, que acham o canal
    # via phone_number_id / page_id / instagram_id (não via external_id).
    def build_local_channel(hub_channel, webhook)
      hub_block = base_hub_block(hub_channel, webhook)

      case @channel_type
      when 'whatsapp_cloud'   then build_whatsapp(hub_channel, hub_block)
      when 'facebook_page', 'facebook' then build_facebook(hub_channel, hub_block)
      when 'instagram'        then build_instagram(hub_channel, hub_block)
      end
    end

    def base_hub_block(hub_channel, webhook)
      {
        'channel_id'             => hub_channel['id'],
        'channel_token'          => hub_channel['token'],
        'channel_credentials_id' => hub_channel['channel_credentials_id'],
        'webhook_id'             => webhook['id'],
        'public_link'            => build_public_link(hub_channel['token']),
        'status'                 => 'active',
        # Marca pro cleanup: este canal foi LINKADO (não criado), então no
        # destroy do inbox a gente só remove o webhook, não o canal Hub.
        'linked'                 => true
      }
    end

    def build_public_link(channel_token)
      return nil if channel_token.blank?
      "#{MetaBaseUrl.hub_frontend_url}/connect/#{channel_token}"
    end

    def build_whatsapp(hub_channel, hub_block)
      meta = hub_channel['meta_connection'] || {}
      Channel::Whatsapp.create!(
        phone_number: extract_phone_number(meta),
        provider: 'whatsapp_cloud',
        provider_config: {
          # Não há access_token Meta — todo tráfego sai via Hub proxy usando
          # channel_token na Authorization. api_key fica vazio de propósito.
          'api_key'             => '',
          'phone_number_id'     => meta['phone_number_id'].to_s,
          'business_account_id' => meta['waba_id'].to_s,
          'waba_id'             => meta['waba_id'].to_s,
          'evolution_hub'       => hub_block
        }
      )
    end

    def build_facebook(hub_channel, hub_block)
      fb = hub_channel['facebook_connection'] || {}
      Channel::FacebookPage.create!(
        # access_token/user_access_token ficam vazios — outbound vai via Hub
        # proxy com channel_token. page_id é o que o inbound usa pra rotear.
        user_access_token: '',
        page_access_token: '',
        page_id: fb['page_id'].presence || "pending_#{SecureRandom.hex(6)}",
        evolution_hub_meta: hub_block
      )
    end

    def build_instagram(hub_channel, hub_block)
      ig = hub_channel['instagram_connection'] || {}
      Channel::Instagram.create!(
        access_token: '',
        instagram_id: ig['instagram_user_id'].presence || "pending_#{SecureRandom.hex(6)}",
        expires_at: 60.days.from_now,
        evolution_hub_meta: hub_block
      )
    end

    # WhatsApp Channel exige phone_number único e não-nulo, mas o Hub não
    # devolve o número formatado no GET (só phone_numbers[].display_phone_number
    # quando disponível). Usa o primeiro display number; fallback pra
    # phone_number_id se não tiver lista. NUNCA fica vazio.
    def extract_phone_number(meta)
      list = meta['phone_numbers']
      if list.is_a?(Array) && list.first.is_a?(Hash) && list.first['display_phone_number'].present?
        list.first['display_phone_number']
      elsif meta['phone_number_id'].present?
        "+pn_#{meta['phone_number_id']}"
      else
        "+0000#{SecureRandom.random_number(10**10)}"
      end
    end

    def create_inbox(channel)
      Inbox.create!(channel: channel, name: @name)
    end
  end
end
