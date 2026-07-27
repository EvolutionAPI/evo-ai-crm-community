# frozen_string_literal: true

module Products
  # Remote product-import sources. Each connector maps a store's catalog into
  # Products::BulkImporter's item shape, reusing the CSV import's pipeline.
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
