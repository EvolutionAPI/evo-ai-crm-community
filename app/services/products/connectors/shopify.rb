# frozen_string_literal: true

module Products
  module Connectors
    # Imports products from a Shopify store's Admin API. Credentials: `shop_domain`
    # (e.g. my-shop.myshopify.com) + `access_token` (a custom-app Admin API token with
    # read_products). One-time, credential-based — no OAuth dance for the import path.
    class Shopify < Base
      API_VERSION = '2024-01'
      # Shopify's Admin API caps `limit` at 250; anything larger is silently clamped, so
      # we page with the cursor (Link header) up to MAX_ITEMS instead of over-asking.
      PAGE_SIZE = 250

      def fetch_items
        shop  = normalize_shop(require_credential(:shop_domain))
        token = require_credential(:access_token)
        headers = { 'X-Shopify-Access-Token' => token, 'Accept' => 'application/json' }

        items = []
        # limit lives in the URL: a cursor request (page_info) rejects extra query params,
        # and the Link "next" URL already carries limit+page_info, so we pass it verbatim.
        url = "https://#{shop}/admin/api/#{API_VERSION}/products.json?limit=#{PAGE_SIZE}"
        pages = 0

        while url && pages < max_pages(PAGE_SIZE)
          response = get(url, headers: headers)
          raise ConnectorError, "Shopify responded #{response.code}" unless response.success?

          items.concat(Array(response.parsed_response['products']).map { |product| map_product(product) })
          pages += 1
          break if items.size >= MAX_ITEMS

          url = next_page_url(response)
        end

        items.first(MAX_ITEMS)
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
          stock_quantity: variant['inventory_quantity'],
          # EVO-2226: image URLs are ingested + attached post-import (best-effort).
          image_urls: Array(product['images']).filter_map { |img| img['src'].presence }.first(5).presence
          # currency: Shopify carries it on the shop, not the product — left unset so the
          # column default (BRL) applies; the user adjusts post-import if needed.
        }.compact
      end
    end
  end
end
