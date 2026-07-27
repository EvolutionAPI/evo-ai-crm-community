# frozen_string_literal: true

require 'ipaddr'
require 'resolv'

module Products
  module Connectors
    # Base for a product-import source: fetches a store's catalog with one-time
    # credentials and maps it into the item shape Products::BulkImporter consumes, so a
    # remote import reuses the CSV import's dry-run + import path.
    class Base
      # What we return is what the client posts to /products/bulk, which rejects more.
      MAX_ITEMS = Products::BulkImporter::MAX_ITEMS
      HTTP_TIMEOUT = 15

      # Bounds a store that keeps advertising a next page; counted in requests, so short
      # pages still reach MAX_ITEMS.
      MAX_PAGE_REQUESTS = 25
      # The fetch is synchronous, so the walk must fit inside the 60s proxy read timeout.
      FETCH_DEADLINE = 40

      def initialize(credentials)
        @credentials = (credentials || {}).to_h.with_indifferent_access
        @truncated = false
        @variants_dropped = 0
        # Anchored at build time: the controller fetches immediately after building.
        @deadline = monotonic_now + FETCH_DEADLINE
      end

      # @return [Array<Hash>] items in Products::BulkImporter format.
      def fetch_items
        raise NotImplementedError
      end

      # True when the walk stopped on a budget instead of on the end of the catalog. A
      # catalog ending exactly on MAX_ITEMS reports truncated too.
      attr_reader :truncated
      alias truncated? truncated

      # /products/bulk creates one row per product, so extra variants are counted here
      # rather than carried.
      attr_reader :variants_dropped

      private

      def require_credential(key)
        value = @credentials[key].to_s.strip
        raise ConnectorError, "missing credential: #{key}" if value.blank?

        value
      end

      # The description column is plain text; a store's body_html would leak markup.
      def strip_html(html)
        return nil if html.blank?

        html.gsub(/<[^>]+>/, ' ').squish.presence
      end

      def get(url, **)
        pinned_ip = assert_public_url!(url)
        # follow_redirects: false so a public URL can't bounce the request to an internal one.
        HTTParty.get(url, timeout: HTTP_TIMEOUT, follow_redirects: false,
                          connection_adapter: PinnedAddressAdapter, pinned_ip: pinned_ip,
                          headers: { 'Accept' => 'application/json' }, **)
      rescue HTTParty::Error, SocketError, Timeout::Error, Errno::ECONNREFUSED,
             EOFError, OpenSSL::SSL::SSLError => e
        # Timeout::Error already covers Net::Open/ReadTimeout (its subclasses).
        raise ConnectorError, "could not reach #{self.class.name.demodulize}: #{e.message}"
      end

      # @return [String] the vetted address the request is pinned to, so the client does
      #   not resolve the host a second time (rebinding).
      def assert_public_url!(url)
        uri = URI.parse(url.to_s)
        raise ConnectorError, 'only http(s) URLs are allowed' unless %w[http https].include?(uri.scheme)
        raise ConnectorError, 'invalid host' if uri.host.blank?

        addresses = Resolv.getaddresses(uri.host)
        raise ConnectorError, "could not resolve #{uri.host}" if addresses.empty?
        raise ConnectorError, 'refusing to connect to a private/internal address' if addresses.any? { |a| Products::UrlSafety.private_ip?(a) }

        preferred_address(addresses)
      rescue URI::InvalidURIError, IPAddr::InvalidAddressError
        raise ConnectorError, 'invalid store URL'
      end

      # IPv4 first: pinning removes the client's family fallback, so a v6 address would
      # fail outright on a v4-only host.
      def preferred_address(addresses)
        addresses.find { |addr| addr.exclude?(':') } || addresses.first
      end

      # HTTParty parses by content type: a non-JSON 200 comes back as a String, and
      # String#[] would mine the HTML into a plausible-looking product.
      def parsed_json(response, expected)
        body = response.parsed_response
        return body if body.is_a?(expected)

        raise ConnectorError,
              "#{self.class.name.demodulize} returned a non-JSON response (HTTP #{response.code})"
      end

      # Also records the stop reason: any of these means the catalog may continue.
      def budget_exhausted?(items, requests)
        @truncated = items.size >= MAX_ITEMS || requests >= MAX_PAGE_REQUESTS || past_deadline?
      end

      def past_deadline?
        monotonic_now >= @deadline
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # RFC 5988 Link header, used by Shopify's cursor pagination.
      def next_page_url(response)
        link = response.headers['link']
        return nil if link.blank?

        part = link.split(',').find { |segment| segment.include?('rel="next"') }
        part && part[/<([^>]+)>/, 1]
      end
    end
  end
end
