# frozen_string_literal: true

# Single emit point for purchase-webhook audit records, mirroring
# Webhooks::ErpAuditLogger: persists to the enterprise audit log when the
# overlay is loaded, degrades to a tagged Rails logger line otherwise.
#
# Expected payload keys: :provider, :signature_valid, :result_status,
# :latency_ms. Extra keys (:reason, :purchase_id, ids) pass through.
module Webhooks
  module PurchaseAuditLogger
    module_function

    def emit(payload)
      if defined?(Evo::Enterprise::AuditLog)
        Evo::Enterprise::AuditLog.record!(
          category: 'purchase_webhook',
          payload: payload
        )
      else
        Rails.logger.tagged('purchase_webhook').info(payload.to_json)
      end
    end
  end
end
