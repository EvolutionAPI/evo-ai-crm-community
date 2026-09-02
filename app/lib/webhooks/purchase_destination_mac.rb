# frozen_string_literal: true

# MAC over the query params that choose WHERE a purchase lead lands. The body
# signature cannot cover them — the platform signs only its own payload — so a
# captured delivery would otherwise replay into any tenant or pipeline.
# Minted into the registered URL by `rake evo_purchase_webhook:url`.
module Webhooks
  module PurchaseDestinationMac
    PARAMS = %w[evo_tenant pipeline_id product].freeze
    QUERY_PARAM = 'd'

    # Per-account secret that keys this MAC, kept next to the MAC itself because
    # both the ingress and the mint task read it. Shares the tenant-only prefix
    # of the platform credentials; "DESTINATION" cannot collide with a provider,
    # since providers are only reachable through the adapter registry.
    SECRET_KEY = 'PURCHASE_WEBHOOK_SECRET_DESTINATION'

    module_function

    def canonical(provider, values)
      ([provider.to_s] + PARAMS.map { |key| values[key].to_s }).join('|')
    end

    def mint(secret, provider, values)
      OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret.to_s, canonical(provider, values))
    end
  end
end
