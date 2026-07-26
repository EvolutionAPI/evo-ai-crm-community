# frozen_string_literal: true

module Products
  module Connectors
    # Imports products from a WooCommerce store's REST API (wc/v3). Credentials:
    # `store_url` + `consumer_key` + `consumer_secret` (a read-only API key pair from
    # WooCommerce → Settings → Advanced → REST API). Basic-auth over HTTPS.
    class WooCommerce < Base
      def fetch_items
        base   = normalize_url(require_credential(:store_url))
        key    = require_credential(:consumer_key)
        secret = require_credential(:consumer_secret)

        response = get(
          "#{base}/wp-json/wc/v3/products",
          basic_auth: { username: key, password: secret },
          query: { per_page: MAX_ITEMS, status: 'any' }
        )
        raise ConnectorError, "WooCommerce responded #{response.code}" unless response.success?

        Array(response.parsed_response).map { |product| map_product(product) }
      end

      private

      def normalize_url(value)
        url = value.strip.delete_suffix('/')
        url = "https://#{url}" unless url.match?(%r{\Ahttps?://}i)
        url
      end

      def map_product(product)
        {
          name: product['name'],
          description: strip_html(product['short_description'].presence || product['description']),
          sku: product['sku'].presence,
          default_price: product['price'].presence || product['regular_price'].presence,
          status: product['status'] == 'publish' ? 'active' : 'draft',
          kind: product['virtual'] ? 'digital' : 'physical',
          stock_quantity: product['stock_quantity'],
          purchase_url: product['permalink'].presence
        }.compact
      end
    end
  end
end
