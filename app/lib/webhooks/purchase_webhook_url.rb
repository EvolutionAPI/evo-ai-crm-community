# frozen_string_literal: true

# Mints the URL an operator registers at a purchase platform: the destination
# query (evo_tenant/pipeline_id/product) signed under the same secret rules as
# the ingress (PurchaseWebhookSignatureConcern), so a URL this service refuses
# is one the ingress would refuse too. Used by the pipeline screen and the rake.
module Webhooks
  class PurchaseWebhookUrl
    Result = Struct.new(:url, :host_kind, :error, keyword_init: true)

    # evo_tenant: explicit override for operator tooling (the rake mints for
    # any account); the screen path leaves it nil and uses the bound tenant.
    def mint(provider:, pipeline_id:, product: nil, evo_tenant: nil)
      provider = provider.to_s.downcase
      return Result.new(error: :unknown_provider) unless PurchaseAdapters.registered?(provider)

      pipeline = ::Pipeline.find_by(id: pipeline_id)
      return Result.new(error: :pipeline_not_found) if pipeline.nil?
      # A URL to a stage-less pipeline mints fine and then fails on every
      # delivery (the lead needs the entry stage) — refuse here, where the
      # operator can still fix it.
      return Result.new(error: :pipeline_without_stages) unless pipeline.pipeline_stages.exists?

      platform_secret = GlobalConfigService.load("PURCHASE_WEBHOOK_SECRET_#{provider.upcase}", nil).to_s
      return Result.new(error: :credential_missing) if platform_secret.blank?

      mac_secret = resolve_mac_secret(provider, platform_secret)
      return Result.new(error: :destination_secret_required) if mac_secret.nil?

      values = {
        'evo_tenant' => (evo_tenant.presence || bound_tenant_id).to_s,
        'pipeline_id' => pipeline.id.to_s,
        'product' => product.to_s
      }
      query = values.reject { |_k, v| v.blank? }
      query[PurchaseDestinationMac::QUERY_PARAM] = PurchaseDestinationMac.mint(mac_secret, provider, values)

      tenant_for_host = values['evo_tenant']
      Result.new(
        url: "#{base_url(tenant_for_host)}/api/v1/webhooks/purchases/#{provider}?#{query.to_query}",
        host_kind: host_kind(tenant_for_host)
      )
    end

    # What the platform picker needs: which providers exist, which have a
    # credential, and whether the URL destination secret (required for
    # public-credential schemes) is configured.
    def providers_payload
      {
        providers: PurchaseAdapters.keys.map do |key|
          provider = key.to_s
          verifier = PurchaseAdapters.verifier_for(provider)
          {
            provider: provider,
            configured: GlobalConfigService.load("PURCHASE_WEBHOOK_SECRET_#{provider.upcase}", nil).present?,
            requires_destination_secret: verifier&.public_credential? || false
          }
        end,
        destination_secret_configured: GlobalConfigService.load(PurchaseDestinationMac::SECRET_KEY, nil).present?
      }
    end

    private

    # Same rule as the ingress: the account's destination secret when set;
    # fallback to the platform credential ONLY while it is private — for an
    # asymmetric scheme (public key) there is no fallback.
    def resolve_mac_secret(provider, platform_secret)
      destination = GlobalConfigService.load(PurchaseDestinationMac::SECRET_KEY, nil).to_s
      return destination if destination.present?

      verifier = PurchaseAdapters.verifier_for(provider)
      return nil if verifier.nil? || verifier.public_credential?

      platform_secret
    end

    # tenant_id is unused here; an embedding overlay resolves the host per
    # account (whitelabel) and needs to know WHICH account the URL is for.
    def base_url(_tenant_id)
      ENV.fetch('FRONTEND_URL', '').chomp('/')
    end

    def host_kind(_tenant_id)
      'global'
    end

    # Multi-tenant embeddings bind the account per request; standalone has no
    # tenant and mints an unbound URL (the single-account box).
    def bound_tenant_id
      return nil unless defined?(Evo::Enterprise::Licensing) &&
                        Evo::Enterprise::Licensing.respond_to?(:current_tenant_id)

      Evo::Enterprise::Licensing.current_tenant_id
    end
  end
end
