# frozen_string_literal: true

# Cakto puts the shared token INSIDE the JSON body (field `secret`, chosen by
# the user when creating the webhook) — no signature header at all. The
# configured credential is that token. Field name per the public docs as of
# 2026-08-31; confirm against a real delivery before relying on it in production.
module Webhooks
  module PurchaseVerifiers
    class Cakto < Base
      BODY_FIELD = 'secret'

      def self.verify(request:, secret:)
        payload = JSON.parse(request.raw_post)
        return :malformed unless payload.is_a?(Hash)

        provided = payload[BODY_FIELD].to_s
        return :malformed if provided.blank?
        return true if ActiveSupport::SecurityUtils.secure_compare(provided, secret)

        :mismatch
      rescue JSON::ParserError
        :malformed
      end
    end
  end
end
