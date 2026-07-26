# frozen_string_literal: true

require 'stringio'

module Products
  # EVO-2226 (Frente A): downloads a product's remote image URLs (from the
  # import connectors) and attaches them as ActiveStorage blobs. Everything here
  # is best-effort and non-fatal — a failed/blocked/oversized image must never
  # break the product it belongs to (the product already exists at this point).
  #
  # Runs only on a real import (never dry-run) and post-commit, so no network I/O
  # happens inside the bulk transaction.
  class ImageIngestor
    MAX_PER_PRODUCT = 3
    MAX_BYTES = 5 * 1024 * 1024 # 5 MB
    HTTP_TIMEOUT = 8
    ALLOWED_TYPES = %w[image/jpeg image/png image/webp image/gif image/avif].freeze
    EXT_FOR = {
      'image/jpeg' => '.jpg', 'image/png' => '.png', 'image/webp' => '.webp',
      'image/gif' => '.gif', 'image/avif' => '.avif'
    }.freeze

    def self.attach_all(product, urls)
      new(product).attach_all(urls)
    end

    def initialize(product)
      @product = product
    end

    def attach_all(urls)
      Array(urls).first(MAX_PER_PRODUCT).each do |url|
        attach_one(url.to_s)
      rescue StandardError => e
        # Optional path: log and move on, never propagate.
        Rails.logger.warn("[ImageIngestor] product=#{@product.id} skip #{url.inspect}: #{e.class} #{e.message}")
      end
    end

    private

    def attach_one(url)
      return unless safe_public_url?(url)

      body, content_type = fetch_image(url)
      return if body.nil?

      @product.images.attach(
        io: StringIO.new(body),
        filename: filename_for(url, content_type),
        content_type: content_type
      )
    end

    # Returns [body, content_type] only for a successful response that is an
    # allowed image type within the size cap; otherwise nil (skip).
    def fetch_image(url)
      response = HTTParty.get(url, timeout: HTTP_TIMEOUT, follow_redirects: false)
      return unless response.success?

      content_type = parse_content_type(response)
      return unless ALLOWED_TYPES.include?(content_type)

      body = response.body
      return if invalid_body?(body)

      [body, content_type]
    end

    def parse_content_type(response)
      response.headers['content-type'].to_s.split(';').first&.strip&.downcase
    end

    def invalid_body?(body)
      body.nil? || body.bytesize.zero? || body.bytesize > MAX_BYTES
    end

    # SSRF: the image URL comes from the remote store, so re-run the same guard
    # the store connector uses — http(s) only, host must resolve to public IPs.
    def safe_public_url?(url)
      uri = URI.parse(url)
      return false unless %w[http https].include?(uri.scheme)

      Products::UrlSafety.public_host?(uri.host)
    rescue URI::InvalidURIError
      false
    end

    def filename_for(url, content_type)
      base = File.basename(URI.parse(url).path.to_s)
      return base if base.present? && File.extname(base).present?

      "image-#{SecureRandom.hex(4)}#{EXT_FOR.fetch(content_type, '')}"
    rescue URI::InvalidURIError
      "image-#{SecureRandom.hex(4)}#{EXT_FOR.fetch(content_type, '')}"
    end
  end
end
