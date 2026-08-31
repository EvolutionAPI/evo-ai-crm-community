# frozen_string_literal: true

# Hotmart authenticates by static token, not by signature: every delivery
# carries the account's hottok verbatim in a header. The configured credential
# IS that token. Header name per the public docs (webhook 2.0) as of 2026-08-31;
# confirm against a real delivery before relying on it in production.
module Webhooks
  module PurchaseVerifiers
    class Hotmart < Base
      HEADER = 'X-Hotmart-Hottok'

      def self.verify(request:, secret:)
        provided = request.headers[HEADER].to_s
        return :malformed if provided.blank?
        return true if ActiveSupport::SecurityUtils.secure_compare(provided, secret)

        :mismatch
      end
    end
  end
end
