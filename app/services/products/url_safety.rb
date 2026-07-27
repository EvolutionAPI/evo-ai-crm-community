# frozen_string_literal: true

require 'ipaddr'
require 'resolv'

module Products
  # SSRF guard shared by the import connectors (store URLs) and the image
  # ingestor (remote image URLs). Both fetch user-influenced URLs, so both must
  # refuse anything that resolves to a private/loopback/link-local/reserved
  # address. Extracted from Connectors::Base (EVO-1785) for reuse by EVO-2226.
  module UrlSafety
    PRIVATE_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 64:ff9b::/96 2002::/16 fc00::/7 fe80::/10 ff00::/8
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    module_function

    # A single resolved address is private/reserved (or unparseable → unsafe).
    #
    # IPv4-mapped IPv6 is normalised to its IPv4 form first: IPAddr#include?
    # never matches across families, so without this an AAAA record pointing at
    # `::ffff:169.254.169.254` walks straight through the IPv4 ranges above.
    # 6to4 (2002::/16) and NAT64 (64:ff9b::/96) embed IPv4 the same way without
    # being convertible, so they are refused wholesale.
    def private_ip?(addr)
      ip = IPAddr.new(addr.to_s)
      ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
      PRIVATE_RANGES.any? { |range| range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end

    # True only when `host` resolves and every resolved address is public.
    #
    # Note: the caller connects by hostname, so the HTTP client resolves it a
    # second time — a record with a very short TTL can in principle answer
    # differently between the two lookups. Closing that window means pinning the
    # connection to a validated address (Net::HTTP#ipaddr=); tracked as
    # follow-up hardening rather than done here, since it changes the transport.
    def public_host?(host)
      return false if host.blank?

      addresses = Resolv.getaddresses(host)
      return false if addresses.empty?

      addresses.none? { |addr| private_ip?(addr) }
    end
  end
end
