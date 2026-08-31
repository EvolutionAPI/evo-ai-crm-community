# frozen_string_literal: true

# The house scheme (CRM-320): HMAC-SHA256 over the raw body, hex-encoded in the
# `X-Evo-Signature` header as `sha256=<hex>`. Used by platforms that let the
# operator configure how deliveries are signed (Virtu).
module Webhooks
  module PurchaseVerifiers
    class EvoHmac < Base
      HEADER = 'X-Evo-Signature'

      def self.verify(request:, secret:)
        provided = request.headers[HEADER].to_s
        return :malformed unless provided.start_with?('sha256=')

        expected = "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, request.raw_post)}"
        return true if ActiveSupport::SecurityUtils.secure_compare(expected, provided)

        :mismatch
      end
    end
  end
end
