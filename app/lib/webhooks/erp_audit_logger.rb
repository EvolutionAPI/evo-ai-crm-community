# frozen_string_literal: true

# Single emit point for ERP-webhook audit records (EVO-1735 S3.0).
#
# When the enterprise overlay is loaded, persists a structured row to
# `evo_enterprise_audit_log` via `Evo::Enterprise::AuditLog.record!`.
# In community-only deploys the constant is undefined, so the call
# degrades gracefully to a tagged Rails logger line — still single-
# write, still queryable via the standard log pipeline.
#
# Expected payload keys: :provider, :signature_valid, :idempotency_hit,
# :items_count, :result_status, :latency_ms. Extra keys (e.g. :reason)
# pass through unchanged.
module Webhooks
  module ErpAuditLogger
    module_function

    def emit(payload)
      if defined?(Evo::Enterprise::AuditLog)
        Evo::Enterprise::AuditLog.record!(
          category: 'erp_webhook',
          payload: payload
        )
      else
        Rails.logger.tagged('erp_webhook').info(payload.to_json)
      end
    end
  end
end
