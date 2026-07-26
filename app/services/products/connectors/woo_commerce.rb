# frozen_string_literal: true

module Products
  module Connectors
    # Imports products from a WooCommerce store's REST API (wc/v3). Credentials:
    # `store_url` + `consumer_key` + `consumer_secret` (a read-only API key pair from
    # WooCommerce → Settings → Advanced → REST API). Basic-auth over HTTPS.
    class WooCommerce < Base
      # WooCommerce caps `per_page` at 100; asking for more silently returns 100, so we
      # page with ?page=N (bounded by X-WP-TotalPages) up to MAX_ITEMS.
      PAGE_SIZE = 100

      def fetch_items
        base   = normalize_url(require_credential(:store_url))
        key    = require_credential(:consumer_key)
        secret = require_credential(:consumer_secret)
        auth   = { username: key, password: secret }
        endpoint = "#{base}/wp-json/wc/v3/products"

        items = []
        page = 1
        loop do
          response = get(endpoint, basic_auth: auth, query: { per_page: PAGE_SIZE, status: 'any', page: page })
          raise ConnectorError, "WooCommerce responded #{response.code}" unless response.success?

          batch = Array(response.parsed_response)
          items.concat(batch.map { |product| map_product(product) })
          break if batch.empty? || items.size >= MAX_ITEMS ||
                   page >= total_pages(response) || page >= max_pages(PAGE_SIZE)

          page += 1
        end

        items.first(MAX_ITEMS)
      end

      private

      # WooCommerce advertises the page count in this header; absent/blank → 0, which
      # (page 1 >= 0) stops after the first page — the safe single-page default.
      def total_pages(response)
        response.headers['x-wp-totalpages'].to_i
      end

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
