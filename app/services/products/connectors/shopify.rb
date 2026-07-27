# frozen_string_literal: true

module Products
  module Connectors
    # Imports products from a Shopify store's Admin API. Credentials: `shop_domain` +
    # `access_token` (custom-app token with read_products), one-time, no OAuth.
    class Shopify < Base
      API_VERSION = '2024-01'
      # The Admin API silently clamps `limit` at 250, so we page with the cursor instead.
      PAGE_SIZE = 250

      def fetch_items
        shop  = normalize_shop(require_credential(:shop_domain))
        token = require_credential(:access_token)
        headers = { 'X-Shopify-Access-Token' => token, 'Accept' => 'application/json' }

        items = []
        # limit lives in the URL: a page_info request rejects extra query params, and the
        # Link "next" URL already carries both.
        url = "https://#{shop}/admin/api/#{API_VERSION}/products.json?limit=#{PAGE_SIZE}"
        requests = 0

        while url
          response = get(url, headers: headers)
          raise ConnectorError, "Shopify responded #{response.code}" unless response.success?

          payload = parsed_json(response, Hash)
          items.concat(Array(payload['products']).map { |product| map_product(product) })
          requests += 1
          break if budget_exhausted?(items, requests)

          url = next_shop_page_url(response, shop)
        end

        items.first(MAX_ITEMS)
      end

      private

      # The Link header is store-controlled and every page request carries the access
      # token, so pin the host: assert_public_url! only rules out internal addresses.
      def next_shop_page_url(response, shop)
        url = next_page_url(response)
        return nil if url.blank?

        uri = URI.parse(url)
        return url if uri.scheme == 'https' && uri.host.to_s.casecmp?(shop)

        raise ConnectorError, 'refusing to follow a pagination link to another host'
      rescue URI::InvalidURIError
        raise ConnectorError, 'invalid pagination link'
      end

      # Accept a full URL or a bare host.
      def normalize_shop(value)
        value.sub(%r{\Ahttps?://}i, '').sub(%r{/.*\z}, '')
      end

      def map_product(product)
        variants = Array(product['variants'])
        variant = variants.first || {}
        # One row per product: only the first variant survives, the rest are reported.
        @variants_dropped += variants.size - 1 if variants.size > 1

        {
          name: product['title'],
          description: strip_html(product['body_html']),
          sku: variant['sku'].presence,
          default_price: variant['price'],
          # active | archived | draft  →  our active | draft
          status: product['status'] == 'active' ? 'active' : 'draft',
          # No physical/digital flag on Shopify; "needs no shipping" is the closest signal.
          kind: variant['requires_shipping'] == false ? 'digital' : 'physical',
          stock_quantity: variant['inventory_quantity'],
          # Ingested + attached post-import, best-effort (EVO-2226).
          image_urls: Array(product['images'])
                        .filter_map { |img| img['src'].presence }
                        .first(Products::ImagePolicy::MAX_PER_IMPORT).presence
          # currency: lives on the shop, not the product — left unset so the column
          # default applies.
        }.compact
      end
    end
  end
end
