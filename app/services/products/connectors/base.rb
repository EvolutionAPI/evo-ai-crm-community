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

      # EVO-2225: backstops for a paginated walk. MAX_ITEMS is what normally ends it;
      # these bound a store that keeps advertising a next page (broken or hostile).
      # MAX_PAGE_REQUESTS bounds *requests*, so it is generous enough to still reach
      # MAX_ITEMS when a store hands back pages smaller than we asked for (a host that
      # clamps WooCommerce's per_page to 20 still yields 500 items in 25 requests).
      MAX_PAGE_REQUESTS = 25
      # import_fetch is synchronous, so the whole walk has to fit inside the proxy's read
      # timeout (nginx defaults to 60s on the CRM location). Checked between pages, so
      # the worst case is FETCH_DEADLINE + one in-flight HTTP_TIMEOUT.
      FETCH_DEADLINE = 40

      # SSRF guard: the store URL/domain is user-supplied, so refuse anything that
      # resolves to a private, loopback, link-local or reserved address — otherwise a
      # products.create holder could aim the fetch at internal services (metadata IPs,
      # databases, admin ports).
      PRIVATE_RANGES = %w[
        0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
        172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15
        ::1/128 fc00::/7 fe80::/10
      ].map { |cidr| IPAddr.new(cidr) }.freeze

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

      # True when the walk stopped on a budget rather than on the end of the catalog —
      # i.e. the store may still hold products we did not fetch. The caller surfaces it
      # so an over-MAX_ITEMS catalog is not truncated silently (the bug EVO-2225 is about,
      # one ceiling up). Conservative: a catalog ending exactly on MAX_ITEMS also reports
      # truncated, since we stop before asking for the page that would prove otherwise.
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
        raise ConnectorError, 'refusing to connect to a private/internal address' if addresses.any? { |a| private_address?(a) }
      rescue URI::InvalidURIError, IPAddr::InvalidAddressError
        raise ConnectorError, 'invalid store URL'
      end

      def private_address?(addr)
        ip = IPAddr.new(addr)
        PRIVATE_RANGES.any? { |range| range.include?(ip) }
      end

      # Stop condition shared by the paginated connectors. Records why we stopped: any
      # of these means the catalog may continue past what we return.
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
