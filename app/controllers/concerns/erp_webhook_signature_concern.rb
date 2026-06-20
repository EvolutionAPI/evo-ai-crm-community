# frozen_string_literal: true

# HMAC SHA-256 verification for ERP webhook callbacks (EVO-1735 S3.0).
#
# Mirrors the pattern of `EvolutionHubSignatureConcern` (header swapped
# to `X-Evo-Signature`, secret resolved per-provider) and adds an audit
# emit before every `head :unauthorized` so that AC9 — "audit on every
# path, including 401" — is satisfied even when `before_action` short-
# circuits the action.
#
# Shared secret lookup:
#   `ERP_WEBHOOK_SECRET_<PROVIDER_UPCASE>` via `GlobalConfigService`.
#
# Failure modes (all → 401, audit emit, no body):
#   * secret blank          → reason: :secret_missing
#   * header missing/malformed → reason: :malformed
#   * HMAC mismatch         → reason: :mismatch
#
# All three render the same 401 body with `code: INVALID_SIGNATURE` —
# the granular `reason` lives only in the audit record so the wire does
# not leak why the rejection happened.
module ErpWebhookSignatureConcern
  extend ActiveSupport::Concern

  HEADER = 'X-Evo-Signature'

  private

  def verify_erp_signature!
    # `check_provider_known!` runs first (see ErpController) so
    # `params[:provider]` is guaranteed to be a key in the adapter
    # registry by the time we get here — i.e. an allow-listed token,
    # not arbitrary path input. No further sanitization needed before
    # interpolating into the env var name.
    provider = params[:provider].to_s
    secret = GlobalConfigService.load("ERP_WEBHOOK_SECRET_#{provider.upcase}", nil).to_s

    if secret.blank?
      Rails.logger.warn(
        "ERP webhook: refused — ERP_WEBHOOK_SECRET_#{provider.upcase} is not configured"
      )
      return reject_erp_signature!(:secret_missing)
    end

    provided = request.headers[HEADER].to_s
    unless provided.start_with?('sha256=')
      Rails.logger.warn(
        "ERP webhook: refused — missing or malformed signature header. " \
        "Got=#{provided.inspect[0, 80]}, body_size=#{request.raw_post.bytesize}"
      )
      return reject_erp_signature!(:malformed)
    end

    body = request.raw_post
    expected = "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, body)}"
    unless ActiveSupport::SecurityUtils.secure_compare(expected, provided)
      # Do not log secret length — irrelevant for debugging and a small
      # side-channel oracle on the shared secret.
      Rails.logger.warn(
        "ERP webhook: refused — signature mismatch. body_size=#{body.bytesize}"
      )
      return reject_erp_signature!(:mismatch)
    end

    true
  end

  # Emit audit BEFORE responding 401 — the action `#receive` does not
  # run when `before_action` returns false, so AC9 would otherwise lose
  # every 401 sample. The emit shape mirrors the success-path emit on
  # the controller (latency_ms=0, items_count=0, signature_valid=false).
  def reject_erp_signature!(reason)
    Webhooks::ErpAuditLogger.emit(
      provider: params[:provider].to_s,
      signature_valid: false,
      idempotency_hit: false,
      items_count: 0,
      result_status: 'error',
      latency_ms: 0,
      reason: reason
    )
    error_response(
      ApiErrorCodes::INVALID_SIGNATURE,
      'ERP webhook signature invalid',
      status: :unauthorized
    )
  end
end
