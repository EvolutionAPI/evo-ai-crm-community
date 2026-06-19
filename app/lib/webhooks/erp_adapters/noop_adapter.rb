# frozen_string_literal: true

# Pass-through adapter used to exercise the registry contract in specs.
# It assumes the inbound payload already matches the canonical
# `{ products: [...] }` shape — no mapping, no validation.
#
# In production this adapter is registered but has no shared secret
# configured, so `verify_erp_signature!` rejects every real request with
# 401 before reaching the action. Specs override credentials per example.
module Webhooks
  module ErpAdapters
    class NoopAdapter
      def to_bulk_params(payload)
        { products: payload['products'] || [] }
      end
    end
  end
end
