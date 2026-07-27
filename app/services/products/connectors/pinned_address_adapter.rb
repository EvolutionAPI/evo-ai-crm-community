# frozen_string_literal: true

module Products
  module Connectors
    # Dials the address the SSRF guard already vetted instead of letting the HTTP client
    # resolve the host a second time — a TTL-0 record can otherwise answer public to the
    # guard and internal to the connect (DNS rebinding). Only the TCP address is fixed:
    # the Host header, SNI and certificate verification still use the hostname.
    class PinnedAddressAdapter < HTTParty::ConnectionAdapter
      def connection
        super.tap do |http|
          pinned = options[:pinned_ip]
          http.ipaddr = pinned if pinned.present?
        end
      end
    end
  end
end
