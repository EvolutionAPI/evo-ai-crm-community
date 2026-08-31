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

      class << self
        def verify(request:, secret:)
          signature = decode_signature(request.headers[SIGNATURE_HEADER].to_s)
          return :malformed if signature.nil?

          timestamp = request.headers[TIMESTAMP_HEADER].to_s
          return :malformed if timestamp.blank?
          return :stale_timestamp unless fresh?(timestamp)

          public_key = load_public_key(secret)
          return :verifier_key_invalid if public_key.nil?

          message = "#{request.path}:POST:#{request.raw_post}:#{timestamp}"
          digest = OpenSSL::Digest::SHA256.digest(message)
          return true if public_key.verify(nil, signature, digest)

          :mismatch
        rescue OpenSSL::PKey::PKeyError
          :mismatch
        end

        private

        def fresh?(timestamp)
          millis = timestamp.to_i
          return false if millis.zero?

          now_ms = (Time.current.to_f * 1000).round
          (now_ms - millis).abs <= WINDOW_MS
        end

        def decode_signature(raw)
          return nil if raw.blank?

          padded = raw + '=' * ((4 - raw.length % 4) % 4)
          Base64.urlsafe_decode64(padded)
        rescue ArgumentError
          nil
        end

        # Accepts the two shapes an operator plausibly pastes: the PEM block, or
        # the raw 32-byte key base64-encoded (either alphabet).
        def load_public_key(secret)
          material = secret.to_s.strip
          if material.start_with?('-----')
            key = OpenSSL::PKey.read(material)
            # A PEM of the wrong algorithm (an RSA key pasted by mistake) must
            # read as a credential problem, not depend on how this OpenSSL build
            # reacts to verify(nil, ...) on a non-Ed25519 key.
            return key.respond_to?(:oid) && key.oid == 'ED25519' ? key : nil
          end

          raw = begin
            Base64.urlsafe_decode64(material + '=' * ((4 - material.length % 4) % 4))
          rescue ArgumentError
            begin
              Base64.strict_decode64(material)
            rescue ArgumentError
              nil
            end
          end
          return nil unless raw&.bytesize == 32

          OpenSSL::PKey.new_raw_public_key('ED25519', raw)
        rescue OpenSSL::PKey::PKeyError
          nil
        end
      end
    end
  end
end
