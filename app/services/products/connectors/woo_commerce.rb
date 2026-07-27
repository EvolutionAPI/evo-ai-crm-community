# frozen_string_literal: true

module Products
  module Connectors
    # Imports products from a WooCommerce store's REST API (wc/v3). Credentials:
    # `store_url` + `consumer_key` + `consumer_secret` (a read-only API key pair from
    # WooCommerce → Settings → Advanced → REST API). Basic-auth over HTTPS.
    class WooCommerce < Base
      # WooCommerce caps `per_page` at 100; asking for more silently returns 100, so we
      # page with ?page=N up to MAX_ITEMS.
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
          response = get(endpoint, basic_auth: auth, query: page_query(page))
          raise ConnectorError, "WooCommerce responded #{response.code}" unless response.success?

          batch = parsed_json(response, Array)
          count_dropped_variations(batch)
          items.concat(batch.map { |product| map_product(product) })
          # `page` doubles as the request count: one request per iteration, starting at 1.
          break if budget_exhausted?(items, page) || !more_pages?(batch, page, response)

          page += 1
        end

        items.first(MAX_ITEMS)
      end

      private

      # orderby=id keeps the offset window stable: under the wc/v3 default (date desc) a
      # product created mid-walk shifts later pages and resurfaces an item, which
      # BulkImporter rejects as a duplicated SKU — taking the whole batch down.
      def page_query(page)
        { per_page: PAGE_SIZE, status: 'any', page: page, orderby: 'id', order: 'asc' }
      end

      # A full page is the continuation signal, and it needs no header. X-WP-TotalPages
      # bounds the walk when it arrives, but it is non-standard and a CDN/WAF can strip
      # it — trusting it alone would cut the import at page 1.
      def more_pages?(batch, page, response)
        return false if batch.empty?

        total = total_pages(response)
        return page < total if total.positive?

        batch.size >= PAGE_SIZE
      end

      # A variable product's children are separate wc/v3 records; /products/bulk has no
      # room for them, so the parent lands alone and the count is reported.
      def count_dropped_variations(batch)
        @variants_dropped += batch.sum { |product| Array(product['variations']).size }
      end

      def total_pages(response)
        response.headers['x-wp-totalpages'].to_i
      end

      # The key pair travels in a Basic-auth header, so plain http would put it on the
      # wire in base64. A scheme-less URL is assumed https; an explicit http:// is
      # refused rather than silently upgraded, so the user knows what changed.
      def normalize_url(value)
        url = value.strip.delete_suffix('/')
        return "https://#{url}" unless url.match?(%r{\Ahttps?://}i)

        if url.match?(%r{\Ahttp://}i)
          raise ConnectorError,
                'store URL must use https:// — the consumer key/secret travel in the request'
        end

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
          purchase_url: product['permalink'].presence,
          # EVO-2226: image URLs are ingested + attached post-import (best-effort).
          image_urls: Array(product['images'])
                        .filter_map { |img| img['src'].presence }
                        .first(Products::ImagePolicy::MAX_PER_IMPORT).presence
        }.compact
      end
    end
  end
end
