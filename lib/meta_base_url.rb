# frozen_string_literal: true

# Single source of truth for the Meta Graph API base URL across the CRM.
#
# When the Evolution Hub feature is enabled and fully configured, ALL outbound
# Meta calls (WhatsApp Cloud, Facebook Messenger, Instagram Graph) are routed
# through the Hub's transparent /meta/* proxy. Services should ask this
# helper for the URL prefix instead of hard-coding `graph.facebook.com` /
# `graph.instagram.com` / a version literal.
#
# Forcing `v23.0` as the only API version is intentional: the existing
# services were inconsistent (v23.0, v18.0, v11.0). Centralising here both
# fixes the inconsistency and makes the Hub-vs-direct switch a single line.
module MetaBaseUrl
  META_API_VERSION = 'v23.0'

  # Kinds map to the surface area each service hits. We collapse Instagram
  # Messenger (which is the Facebook Page graph endpoint under the hood) into
  # :facebook so the URL is consistent with how Meta themselves namespace it.
  KINDS = %i[whatsapp facebook instagram].freeze

  class << self
    # Returns the base URL prefix.
    #
    # Hub OFF — includes the Graph API version segment, since callers hit
    # `graph.facebook.com` / `graph.instagram.com` directly.
    # Hub ON  — version is dropped: the Hub's /meta/* proxy abstracts the API
    # version internally and rejects calls that include it (404 on the
    # extra path segment).
    #
    # Examples:
    #   MetaBaseUrl.for(:whatsapp)  # => "https://graph.facebook.com/v23.0" (Hub OFF)
    #                                 # => "https://api.evohub.ai/meta" (Hub ON)
    def for(kind)
      kind = normalize(kind)

      if enabled?
        "#{hub_url}/meta"
      else
        case kind
        when :instagram then "https://graph.instagram.com/#{META_API_VERSION}"
        else                "https://graph.facebook.com/#{META_API_VERSION}"
        end
      end
    end

    # True when both the toggle is on AND the required keys are populated.
    # Identical truth-table as `evolutionHubEnabled` exposed in /global_config.
    def enabled?
      flag = GlobalConfigService.load('EVOLUTION_HUB_ENABLED', 'false').to_s
      ActiveModel::Type::Boolean.new.cast(flag) && IntegrationRequirements.configured?('evolution_hub')
    end

    # Hub URLs são FIXAS — o Hub é um serviço único da Evolution Foundation,
    # não muda por instalação do CRM. Cada CRM open-source self-hosted bate
    # nesse Hub central; o que muda por instalação é só a API key do tenant
    # (EVOLUTION_HUB_API_KEY no GlobalConfigService).

    HUB_API_URL = 'https://api.evohub.ai'
    HUB_FRONTEND_URL = 'https://app.evohub.evolutionfoundation.com.br'

    # Bare Hub URL (no /meta suffix) — used by Evolution Hub admin client
    # to hit /api/v1/channels, /api/v1/auth/me, etc.
    def hub_url
      HUB_API_URL
    end

    # Frontend URL pra construir public_link (/connect/:token) que abre
    # a UI Pronta do Hub no browser do operador.
    def hub_frontend_url
      HUB_FRONTEND_URL
    end

    private

    def normalize(kind)
      sym = kind.to_sym
      return :facebook if sym == :instagram_messenger
      raise ArgumentError, "MetaBaseUrl.for unsupported kind: #{kind.inspect}" unless KINDS.include?(sym)

      sym
    end
  end
end
