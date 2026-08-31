# frozen_string_literal: true

# Kiwify signs asymmetrically: Ed25519 over SHA-256("{path}:POST:{raw_body}:{timestamp}")
# (prehashed), signature base64url-unpadded in `x-kiwify-digital-signature`,
# unix-milliseconds timestamp in `x-kiwify-timestamp`, 5-minute window. The
# configured credential is the PUBLIC key Kiwify hands the account (PEM, or the
# 32 raw bytes base64-encoded) — there is no shared secret in this scheme.
# Scheme per the public docs as of 2026-08-31 (the Banking webhook doc); confirm
# the product-sale webhook signs identically before relying on it in production.
module Webhooks
  module PurchaseVerifiers
    class Kiwify < Base
      SIGNATURE_HEADER = 'x-kiwify-digital-signature'
      TIMESTAMP_HEADER = 'x-kiwify-timestamp'
      WINDOW_MS = 5 * 60 * 1000

      # The credential is a public key: fine for verifying, forgeable as a MAC
      # key — the destination MAC must come from the account's own secret.
      def self.public_credential?
        true
      end

      class << self
        def verify(request:, secret:)
          signature = decode_signature(request.headers[SIGNATURE_HEADER].to_s)
          return :malformed if signature.nil?

          timestamp = request.headers[TIMESTAMP_HEADER].to_s
          return :malformed unless timestamp.match?(/\A\d+\z/)
          return :stale_timestamp unless fresh?(timestamp)

          public_key = load_public_key(secret)
          return :verifier_key_invalid if public_key.nil?

          return true if signed_messages(request, timestamp).any? { |m| verified?(public_key, signature, m) }

          :mismatch
        end

        private

        # The registered URL carries the destination query string, and the doc
        # says only "{url_path}" — so both readings are tried. Neither is
        # forgeable: the signature still has to verify against the account's
        # public key, only the message the account's own platform signed passes.
        def signed_messages(request, timestamp)
          [request.path, request.fullpath].uniq.map do |path|
            "#{path}:POST:#{request.raw_post}:#{timestamp}"
          end
        end

        def verified?(public_key, signature, message)
          public_key.verify(nil, signature, OpenSSL::Digest::SHA256.digest(message))
        rescue OpenSSL::PKey::PKeyError
          false
        end

        def fresh?(timestamp)
          millis = timestamp.to_i
          return false if millis.zero?

          now_ms = (Time.current.to_f * 1000).round
          (now_ms - millis).abs <= WINDOW_MS
        end

        def decode_signature(raw)
          return nil if raw.blank?

          Base64.urlsafe_decode64(pad_base64(raw))
        rescue ArgumentError
          nil
        end

        # Accepts the two shapes an operator plausibly pastes: the PEM block, or
        # the raw 32-byte key base64-encoded (either alphabet).
        def load_public_key(secret)
          material = secret.to_s.strip
          return read_pem(material) if material.start_with?('-----')

          raw = decode_raw_key(material)
          return nil unless raw&.bytesize == 32

          OpenSSL::PKey.new_raw_public_key('ED25519', raw)
        rescue OpenSSL::PKey::PKeyError
          nil
        end

        # A PEM of the wrong algorithm (an RSA key pasted by mistake) must read
        # as a credential problem, not depend on how this OpenSSL build reacts
        # to verify(nil, ...) on a non-Ed25519 key.
        def read_pem(material)
          key = OpenSSL::PKey.read(material)
          key.respond_to?(:oid) && key.oid == 'ED25519' ? key : nil
        end

        def decode_raw_key(material)
          Base64.urlsafe_decode64(pad_base64(material))
        rescue ArgumentError
          begin
            Base64.strict_decode64(material)
          rescue ArgumentError
            nil
          end
        end

        def pad_base64(value)
          value + ('=' * ((4 - (value.length % 4)) % 4))
        end
      end
    end
  end
end
