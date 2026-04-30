require 'ipaddr'
require 'resolv'

class Avatar::AvatarFromUrlJob < ApplicationJob
  queue_as :low

  ALLOWED_SCHEMES = %w[http https].freeze
  MAX_REDIRECTS = 0

  def perform(avatarable, avatar_url)
    return unless avatarable.respond_to?(:avatar)
    return unless safe_avatar_url?(avatar_url)

    avatar_file = Down.download(
      avatar_url,
      max_size: 15 * 1024 * 1024,
      max_redirects: MAX_REDIRECTS
    )
    if valid_image?(avatar_file)
      avatarable.avatar.attach(io: avatar_file, filename: avatar_file.original_filename,
                               content_type: avatar_file.content_type)
    end
  rescue Down::NotFound, Down::Error => e
    Rails.logger.error "Exception: invalid avatar url #{avatar_url} : #{e.message}"
  end

  private

  def valid_image?(file)
    return false if file.original_filename.blank?

    # TODO: check if the file is an actual image

    true
  end

  # Block SSRF: reject non-http(s) schemes and any host that resolves to a
  # loopback / link-local / private / reserved address. DNS is resolved here so
  # the decision matches what `Down.download` will hit (with redirects disabled
  # via max_redirects: 0 to close the obvious rebinding window).
  def safe_avatar_url?(url)
    return false if url.blank?

    uri = URI.parse(url.to_s)
    unless ALLOWED_SCHEMES.include?(uri.scheme)
      Rails.logger.warn "[Avatar::AvatarFromUrlJob] Blocked avatar download (scheme): #{url}"
      return false
    end

    host = uri.host
    if host.blank?
      Rails.logger.warn "[Avatar::AvatarFromUrlJob] Blocked avatar download (missing host): #{url}"
      return false
    end

    addresses = resolve_host(host)
    if addresses.empty?
      Rails.logger.warn "[Avatar::AvatarFromUrlJob] Blocked avatar download (DNS failure): #{url}"
      return false
    end

    if addresses.any? { |ip| restricted_ip?(ip) }
      Rails.logger.warn "[Avatar::AvatarFromUrlJob] Blocked avatar download (restricted IP): #{url}"
      return false
    end

    true
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError => e
    Rails.logger.warn "[Avatar::AvatarFromUrlJob] Blocked avatar download (#{e.class}): #{url}"
    false
  end

  def resolve_host(host)
    return [IPAddr.new(host)] if literal_ip?(host)

    Resolv.getaddresses(host).map { |a| IPAddr.new(a) }
  rescue Resolv::ResolvError, IPAddr::InvalidAddressError
    []
  end

  def literal_ip?(host)
    IPAddr.new(host)
    true
  rescue IPAddr::InvalidAddressError
    false
  end

  def restricted_ip?(ip)
    ip.loopback? || ip.private? || ip.link_local? || extra_blocked?(ip)
  end

  IPV4_BLOCKED = [
    IPAddr.new('0.0.0.0/8'),
    IPAddr.new('100.64.0.0/10'),
    IPAddr.new('192.0.0.0/24'),
    IPAddr.new('192.0.2.0/24'),
    IPAddr.new('198.18.0.0/15'),
    IPAddr.new('198.51.100.0/24'),
    IPAddr.new('203.0.113.0/24'),
    IPAddr.new('224.0.0.0/4'),
    IPAddr.new('240.0.0.0/4')
  ].freeze
  IPV6_BLOCKED = [
    IPAddr.new('::/128'),
    IPAddr.new('100::/64'),
    IPAddr.new('2001::/23'),
    IPAddr.new('ff00::/8')
  ].freeze

  def extra_blocked?(ip)
    ranges = ip.ipv4? ? IPV4_BLOCKED : IPV6_BLOCKED
    ranges.any? { |range| range.include?(ip) }
  end
end
