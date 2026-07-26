# frozen_string_literal: true

module Products
  # EVO-1785 (Phase 2): remote product-import sources. Each connector fetches a store's
  # products and maps them into Products::BulkImporter's item shape, so a remote import
  # reuses the whole validated dry-run + import pipeline the CSV import already has.
  module Connectors
    SUPPORTED_SOURCES = %w[shopify woocommerce].freeze

    # @param source [String] one of SUPPORTED_SOURCES
    # @param credentials [Hash] source-specific credentials (one-time, not persisted)
    # @raise [ConnectorError] when the source is unknown
    def self.build(source, credentials)
      klass =
        case source.to_s
        when 'shopify'     then Shopify
        when 'woocommerce' then WooCommerce
        else
          raise ConnectorError, "unsupported import source: #{source.inspect}"
        end

      klass.new(credentials)
    end
  end
end
