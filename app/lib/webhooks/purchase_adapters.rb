# frozen_string_literal: true

# Adapter registry for purchase-webhook ingress (lead capture from payment
# platforms). Mirrors Webhooks::ErpAdapters: each adapter converts a
# provider-specific payload into the canonical lead shape consumed by
# Webhooks::Purchases::LeadCaptureService. Adapters are duck-typed: they only
# need a `#to_lead(payload) -> Hash` instance method (see Base for the shape).
#
# A provider is only reachable when registered here — the controller returns
# 404 for anything else, so no platform is ever enabled without an adapter
# (and therefore without a signature secret convention).
module Webhooks
  module PurchaseAdapters
    # Raised by an adapter when the inbound payload cannot be mapped to the
    # canonical lead shape (missing purchase id, no reachable contact field).
    class MappingError < StandardError
      attr_reader :errors

      def initialize(errors:)
        @errors = errors
        super('Purchase payload mapping failed')
      end
    end

    @adapters = {}

    class << self
      def register(key, klass)
        @adapters[key.to_sym] = klass
      end

      def lookup(key)
        return nil if key.nil?

        @adapters[key.to_sym]
      end

      def registered?(key)
        return false if key.nil?

        @adapters.key?(key.to_sym)
      end

      def clear!
        @adapters = {}
      end
    end
  end
end
