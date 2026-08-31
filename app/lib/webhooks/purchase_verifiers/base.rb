# frozen_string_literal: true

# The purchase-verifier contract: how a platform authenticates its deliveries.
# One verifier per platform, registered next to the adapter — a provider is
# never reachable with the wrong scheme. `verify` returns true or a Symbol
# reason (it never raises for bad input): the reason lands in the audit and the
# response is always the same opaque 401.
module Webhooks
  module PurchaseVerifiers
    class Base
      # @param request [ActionDispatch::Request] the inbound delivery
      # @param secret [String] the tenant's configured credential for this
      #   platform (shared secret, static token or public key — scheme-defined)
      # @return [true, Symbol] true when authentic, else the rejection reason
      def self.verify(request:, secret:)
        raise NotImplementedError, "#{name} must implement .verify"
      end

      # Whether the platform credential is public material (an asymmetric
      # scheme's public key). A public credential can still VERIFY deliveries,
      # but must never key the destination MAC — anyone holding it could mint a
      # valid `d` and redirect deliveries. See PurchaseWebhookSignatureConcern.
      def self.public_credential?
        false
      end
    end
  end
end
