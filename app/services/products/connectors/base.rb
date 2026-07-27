# frozen_string_literal: true

require 'ipaddr'
require 'resolv'

module Products
  module Connectors
    # EVO-1785 (Phase 2): base for a product-import source. A connector authenticates
    # with user-supplied credentials, fetches the store's products over HTTP, and maps
    # them into the SAME item shape Products::BulkImporter consumes — so the fetched
    # products flow through the exact validated dry-run + import path the CSV import
    # already uses. Credentials are one-time (never persisted).
    class Base
      # Cap the fetch at the importer's batch ceiling: whatever we return here is what
      # the client posts to /products/bulk, which rejects anything larger.
      MAX_ITEMS = Products::BulkImporter::MAX_ITEMS
      HTTP_TIMEOUT = 15

      # Bounds a store that keeps advertising a next page. Counted in requests, not items,
      # so it is sized to still reach MAX_ITEMS when pages come back smaller than asked.
      MAX_PAGE_REQUESTS = 25
      # The fetch is synchronous, so the walk has to fit inside the proxy read timeout
      # (60s). Checked between pages: worst case is this plus one in-flight HTTP_TIMEOUT.
      FETCH_DEADLINE = 40

      def initialize(credentials)
        @credentials = (credentials || {}).to_h.with_indifferent_access
        @truncated = false
        # Anchored at build time: the controller fetches immediately after building.
        @deadline = monotonic_now + FETCH_DEADLINE
      end

      # @return [Array<Hash>] items in Products::BulkImporter format.
      def fetch_items
        raise NotImplementedError
      end

      # True when the walk stopped on a budget instead of on the end of the catalog.
      # Conservative: a catalog ending exactly on MAX_ITEMS reports truncated too, since
      # we stop before requesting the page that would prove otherwise.
      attr_reader :truncated
      alias truncated? truncated

      private

      def require_credential(key)
        value = @credentials[key].to_s.strip
        raise ConnectorError, "missing credential: #{key}" if value.blank?

        value
      end

      # Collapse an HTML description to plain text — the product `description` column is
      # plain text and a store's body_html would otherwise leak markup into the catalog.
      def strip_html(html)
        return nil if html.blank?

        html.gsub(/<[^>]+>/, ' ').squish.presence
      end

      def get(url, **)
        assert_public_url!(url)
        # follow_redirects: false so a public URL can't bounce the request to an internal one.
        HTTParty.get(url, timeout: HTTP_TIMEOUT, follow_redirects: false,
                          headers: { 'Accept' => 'application/json' }, **)
      rescue HTTParty::Error, SocketError, Timeout::Error, Errno::ECONNREFUSED,
             EOFError, OpenSSL::SSL::SSLError => e
        # Timeout::Error already covers Net::Open/ReadTimeout (its subclasses).
        raise ConnectorError, "could not reach #{self.class.name.demodulize}: #{e.message}"
      end

      def assert_public_url!(url)
        uri = URI.parse(url.to_s)
        raise ConnectorError, 'only http(s) URLs are allowed' unless %w[http https].include?(uri.scheme)
        raise ConnectorError, 'invalid host' if uri.host.blank?

        addresses = Resolv.getaddresses(uri.host)
        raise ConnectorError, "could not resolve #{uri.host}" if addresses.empty?
        raise ConnectorError, 'refusing to connect to a private/internal address' if addresses.any? { |a| Products::UrlSafety.private_ip?(a) }
      rescue URI::InvalidURIError, IPAddr::InvalidAddressError
        raise ConnectorError, 'invalid store URL'
      end

      # Also records the stop reason: any of these means the catalog may continue past
      # what we return.
      def budget_exhausted?(items, requests)
        @truncated = items.size >= MAX_ITEMS || requests >= MAX_PAGE_REQUESTS || past_deadline?
      end

      def past_deadline?
        monotonic_now >= @deadline
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Parse an RFC 5988 Link header and return the URL flagged rel="next", or nil.
      # Used by cursor-paginated APIs (Shopify) to walk to the following page.
      def next_page_url(response)
        link = response.headers['link']
        return nil if link.blank?

        part = link.split(',').find { |segment| segment.include?('rel="next"') }
        part && part[/<([^>]+)>/, 1]
      end
    end
  end
end
