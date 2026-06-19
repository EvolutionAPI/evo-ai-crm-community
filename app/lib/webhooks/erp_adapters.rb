# frozen_string_literal: true

# Adapter registry for ERP webhook ingress (EVO-1735 S3.0).
#
# Each adapter converts a provider-specific payload shape into the
# canonical `{ products: [...] }` shape consumed by
# `Products::BulkImporter`. Adapters are duck-typed: they only need a
# `#to_bulk_params(payload) -> { products: Array<Hash> }` instance method.
#
# A real provider adapter is added in S3.1 when a customer pilot is
# contracted. The registry ships empty in production except for `:noop`,
# which exists solely to prove the contract end-to-end in specs.
module Webhooks
  module ErpAdapters
    # Raised by an adapter when the inbound ERP payload cannot be mapped
    # to `Products::BulkImporter`'s schema (e.g. missing keys, wrong
    # types). Distinct from `Products::BulkImporter::BulkImportError`,
    # which fires when the *mapped* data fails Evo's business rules.
    class MappingError < StandardError
      attr_reader :errors

      def initialize(errors:)
        @errors = errors
        super('ERP payload mapping failed')
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
