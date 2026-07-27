# frozen_string_literal: true

require 'net/http'
require 'stringio'
require 'uri'

module Products
  # EVO-2226 (Frente A): downloads a product's remote image URLs (from the
  # import connectors) and attaches them as ActiveStorage blobs. Everything here
  # is best-effort and non-fatal — a failed/blocked/oversized image must never
  # break the product it belongs to (the product already exists at this point).
  #
  # Runs only on a real import (never dry-run) and off the request cycle, via
  # Products::AttachRemoteImagesJob — no network I/O inside the bulk transaction
  # and none while the client waits.
  class ImageIngestor
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 8
    USER_AGENT = 'EvolutionCRM-ImageIngestor'

    def self.attach_all(product, urls)
      new(product).attach_all(urls)
    end

    def initialize(product)
      @product = product
      @slots = ImagePolicy.remaining_slots(product)
    end

    def attach_all(urls)
      Array(urls).first(ImagePolicy::MAX_PER_IMPORT).each do |url|
        break if @slots.zero?

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
      @slots -= 1
    end

    # Returns [body, content_type] only for a successful response that is an
    # allowed image type within the size cap; otherwise nil (skip).
    #
    # The body is streamed and abandoned the moment it crosses MAX_BYTES.
    # Buffering it whole and measuring afterwards would let whoever controls the
    # URL decide how much memory this process allocates.
    def fetch_image(url)
      uri = URI.parse(url)

      http_start(uri) do |http|
        http.request(get_request(uri)) do |response|
          # Redirects are not followed: the new target never passed the SSRF guard.
          return nil unless response.is_a?(Net::HTTPSuccess)

          content_type = parse_content_type(response)
          return nil unless ImagePolicy.allowed_type?(content_type)
          return nil if declared_size_exceeded?(response)

          body = read_capped(response)
          return nil if body.nil?

          return [body, content_type]
        end
      end
    end

    def http_start(uri, &)
      Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == 'https',
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT,
        &
      )
    end

    def get_request(uri)
      Net::HTTP::Get.new(uri, 'User-Agent' => USER_AGENT)
    end

    # Cheap pre-check. Content-Length is only trusted to REJECT — a lying or
    # absent header still hits the streaming cap below.
    def declared_size_exceeded?(response)
      declared = response['content-length'].to_i
      declared.positive? && declared > ImagePolicy::MAX_BYTES
    end

    def read_capped(response)
      buffer = String.new(encoding: Encoding::BINARY)

      response.read_body do |chunk|
        buffer << chunk
        return nil if buffer.bytesize > ImagePolicy::MAX_BYTES
      end

      buffer.bytesize.zero? ? nil : buffer
    end

    def parse_content_type(response)
      response['content-type'].to_s.split(';').first&.strip&.downcase
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

      fallback_filename(content_type)
    rescue URI::InvalidURIError
      fallback_filename(content_type)
    end

    def fallback_filename(content_type)
      "image-#{SecureRandom.hex(4)}#{ImagePolicy.extension_for(content_type)}"
    end
  end
end
