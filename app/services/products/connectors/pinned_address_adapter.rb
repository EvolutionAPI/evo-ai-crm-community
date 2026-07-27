# frozen_string_literal: true

module Products
  module Connectors
    # Dials the address the SSRF guard vetted instead of letting the client resolve the
    # host again (DNS rebinding). Only the TCP address is fixed — Host, SNI and
    # certificate verification still use the hostname.
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
