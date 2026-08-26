# frozen_string_literal: true

# Adapter registry for purchase-webhook ingress, mirroring Webhooks::ErpAdapters.
# Adapters are duck-typed: `#to_lead(payload) -> Hash` (shape in Base).
# A provider is reachable ONLY when registered here — everything else 404s, so
# no platform is ever enabled without an adapter and its signature secret.
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
