# frozen_string_literal: true

require 'httparty'

module EvolutionHub
  # Thin HTTParty wrapper around the Hub management API. Used by the CRM to
  # create channels + associated webhooks atomically when the operator
  # creates an Inbox with Evolution Hub enabled.
  #
  # Outbound Meta traffic does NOT pass through this client — it uses
  # MetaBaseUrl.for(...) directly so the Hub's transparent /meta/* proxy
  # sees the channel/Meta token in the Authorization header.
  class Client
    include HTTParty
    default_timeout 10

    class ConfigurationError < StandardError; end
    class RequestError < StandardError
      attr_reader :status, :body, :code, :variables

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
        @code, @variables = parse_structured_error(body)
      end

      private

      # Hub devolve erro estruturado:
      #   { "error": { "code": "PLAN_FORBIDS_SHARED", "message": "...", "variables": {...} } }
      # Esse parser extrai code/variables pra que callers (controller) possam
      # mapear códigos específicos (PLAN_FORBIDS_*, QUOTA_EXCEEDED, etc) em
      # respostas user-friendly em vez de soltar "Evolution Hub error: HTTP 403".
      def parse_structured_error(body)
        return [nil, nil] if body.blank?

        parsed = body.is_a?(Hash) ? body : (JSON.parse(body) rescue nil)
        return [nil, nil] unless parsed.is_a?(Hash)

        err = parsed['error']
        case err
        when Hash
          [err['code'], err['variables']]
        when String
          # Formato legado: "error": "string"
          [nil, nil]
        else
          [nil, nil]
        end
      end
    end

    # POST /api/v1/channels (single-shot create + webhook).
    # Returns a Hash with keys: "channel" (Hash) and optionally "webhook_id".
    #
    # channel_credentials_id (opcional): UUID de uma credencial BYO Meta App
    # registrada previamente pelo user no Hub (POST /api/v1/credentials).
    # Quando presente, o canal usa essa app em vez da shared Evolution Cloud.
    # Plans free e similares exigem BYO — não passar isso = 403 PLAN_FORBIDS_SHARED.
    def create_channel(type:, name:, external_id:, webhook_url:, webhook_secret:,
                       webhook_events: nil, channel_credentials_id: nil)
      post_json('/api/v1/channels', {
        name: name,
        type: type,
        external_id: external_id,
        webhook_url: webhook_url,
        webhook_secret: webhook_secret,
        webhook_events: webhook_events,
        channel_credentials_id: channel_credentials_id
      }.compact)
    end

    # GET /api/v1/me/meta-app-options — descobre quais Meta Apps o user atual
    # pode usar (shared se o plano permite + lista de BYO cadastrados).
    # Resposta:
    #   { "data": { "allowed_modes": ["shared","byo"],
    #               "shared_configured": true, "shared_allowed_by_plan": true,
    #               "byo_allowed_by_plan": true,
    #               "byo_credentials": [{"id":"...","name":"...","app_id":"..."}] } }
    #
    # IMPORTANTE: a API key usada pelo client é a do tenant Hub (não do user
    # final). Pra fluxos multi-tenant onde cada user CRM tem credentials BYO
    # diferentes, considerar autenticar via JWT do user em vez da API key
    # global. Por enquanto isso reflete só o tenant do EvoCRM no Hub.
    def meta_app_options
      get_json('/api/v1/me/meta-app-options')
    end

    # GET /api/v1/me/plan — plano atual do user (tenant) no Hub.
    # Útil pra UI decidir se mostra/esconde botão "criar canal shared".
    def my_plan
      get_json('/api/v1/me/plan')
    end

    # GET /api/v1/channels — lista canais já criados no Hub pelo tenant.
    # Usado pela tela de Settings do EvoCRM pra mostrar preview de
    # "canais existentes no Evolution Hub" depois que o admin cola
    # API URL + token. Hub devolve { "channels": [...] } com cada item
    # contendo id, name, type, status, channel_credentials_id, etc.
    def list_channels
      get_json('/api/v1/channels')
    end

    # GET /api/v1/auth/me — used by EvolutionHubTestService and as a generic
    # "Hub is up and credentials are valid" probe.
    def get_me
      get_json('/api/v1/auth/me')
    end

    # DELETE /api/v1/channels/:id — used when an Inbox tied to a Hub channel
    # is removed in the CRM.
    def delete_channel(channel_id)
      delete_json("/api/v1/channels/#{channel_id}")
    end

    # DELETE /api/v1/webhooks/:id — used alongside delete_channel to remove
    # the paired Hub webhook the CRM created via single-shot CreateWithWebhook.
    # The Hub doesn't cascade webhook deletion when a channel is removed
    # (intentional: webhooks may be shared across channels), so the cleanup
    # has to happen here on the side that owns the lifecycle.
    def delete_webhook(webhook_id)
      delete_json("/api/v1/webhooks/#{webhook_id}")
    end

    private

    def base_url
      # URL é hardcoded em MetaBaseUrl::HUB_API_URL — não precisa checar
      # vazio aqui.
      MetaBaseUrl.hub_url
    end

    def api_key
      key = GlobalConfigService.load('EVOLUTION_HUB_API_KEY', nil)
      raise ConfigurationError, 'EVOLUTION_HUB_API_KEY not configured' if key.blank?
      key
    end

    def headers
      {
        'Authorization' => "Bearer #{api_key}",
        'Content-Type'  => 'application/json',
        'Accept'        => 'application/json'
      }
    end

    def post_json(path, body)
      response = HTTParty.post("#{base_url}#{path}", body: body.to_json, headers: headers, timeout: 10)
      handle(response, "POST #{path}")
    end

    def get_json(path)
      response = HTTParty.get("#{base_url}#{path}", headers: headers, timeout: 10)
      handle(response, "GET #{path}")
    end

    def delete_json(path)
      response = HTTParty.delete("#{base_url}#{path}", headers: headers, timeout: 10)
      handle(response, "DELETE #{path}")
    end

    def handle(response, op)
      if response.code.between?(200, 299)
        response.parsed_response
      else
        raise RequestError.new(
          "Evolution Hub #{op} failed with HTTP #{response.code}",
          status: response.code,
          body: response.body
        )
      end
    end
  end
end
