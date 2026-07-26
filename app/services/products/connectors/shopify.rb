# frozen_string_literal: true

module Products
  module Connectors
    # Imports products from a Shopify store's Admin API. Credentials: `shop_domain`
    # (e.g. my-shop.myshopify.com) + `access_token` (a custom-app Admin API token with
    # read_products). One-time, credential-based — no OAuth dance for the import path.
    class Shopify < Base
      API_VERSION = '2024-01'

      def fetch_items
        shop  = normalize_shop(require_credential(:shop_domain))
        token = require_credential(:access_token)

        response = get(
          "https://#{shop}/admin/api/#{API_VERSION}/products.json",
          headers: { 'X-Shopify-Access-Token' => token, 'Accept' => 'application/json' },
          query: { limit: MAX_ITEMS }
        )
        raise ConnectorError, "Shopify responded #{response.code}" unless response.success?

        Array(response.parsed_response['products']).map { |product| map_product(product) }
      end

      private

      # Accept a full URL or a bare host; the API is always spoken to over the host.
      def normalize_shop(value)
        value.sub(%r{\Ahttps?://}i, '').sub(%r{/.*\z}, '')
      end

      def map_product(product)
        variant = Array(product['variants']).first || {}
        {
          name: product['title'],
          description: strip_html(product['body_html']),
          sku: variant['sku'].presence,
          default_price: variant['price'],
          # active | archived | draft  →  our active | draft
          status: product['status'] == 'active' ? 'active' : 'draft',
          kind: 'physical',
          stock_quantity: variant['inventory_quantity']
          # currency: Shopify carries it on the shop, not the product — left unset so the
          # column default (BRL) applies; the user adjusts post-import if needed.
        }.compact
      end
    end
  end
end
