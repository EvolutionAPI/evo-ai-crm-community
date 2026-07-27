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

          batch = Array(response.parsed_response)
          items.concat(batch.map { |product| map_product(product) })
          # `page` doubles as the request count: one request per iteration, starting at 1.
          break if budget_exhausted?(items, page) || !more_pages?(batch, page, response)

          page += 1
        end

        items.first(MAX_ITEMS)
      end

      private

      # orderby=id keeps the offset window stable. Under the wc/v3 default (date desc) a
      # product created mid-walk shifts every later page, so an item resurfaces on the
      # next one — and BulkImporter rejects the whole batch on a duplicated SKU, turning
      # a benign edit in the store into a failed import.
      def page_query(page)
        { per_page: PAGE_SIZE, status: 'any', page: page, orderby: 'id', order: 'asc' }
      end

      # Header-independent continuation: a page that came back full means there is very
      # likely more. X-WP-TotalPages bounds the walk when it arrives, but it is not
      # required — it is a non-standard header that a CDN/WAF can strip, and treating its
      # absence as "one page only" would silently cut the import at page 1, which is the
      # exact failure EVO-2225 exists to remove.
      def more_pages?(batch, page, response)
        return false if batch.empty?

        total = total_pages(response)
        return page < total if total.positive?

        batch.size >= PAGE_SIZE
      end

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
