# frozen_string_literal: true

# HMAC SHA-256 verification for purchase webhook callbacks. Mirrors
# ErpWebhookSignatureConcern (same header, same failure taxonomy).
#
# Shared secret lookup:
#   `PURCHASE_WEBHOOK_SECRET_<PROVIDER_UPCASE>` via `GlobalConfigService`.
#
# Failure modes (all -> 401, audit emit, one opaque body):
#   * secret blank              -> reason: :secret_missing (fail-closed)
#   * header missing/malformed  -> reason: :malformed
#   * HMAC mismatch             -> reason: :mismatch
module PurchaseWebhookSignatureConcern
  extend ActiveSupport::Concern

  HEADER = 'X-Evo-Signature'

  private

  def verify_purchase_signature!
    secret = purchase_webhook_secret
    return reject_purchase_signature!(:secret_missing) if secret.blank?

    provided = request.headers[HEADER].to_s
    unless provided.start_with?('sha256=')
      Rails.logger.warn(
        'Purchase webhook: refused — missing or malformed signature header. ' \
        "Got=#{provided.inspect[0, 80]}, body_size=#{request.raw_post.bytesize}"
      )
      return reject_purchase_signature!(:malformed)
    end

    return true if valid_purchase_signature?(secret, provided)

    Rails.logger.warn("Purchase webhook: refused — signature mismatch. body_size=#{request.raw_post.bytesize}")
    reject_purchase_signature!(:mismatch)
  end

  # check_provider_known! runs first, so `params[:provider]` is an allow-listed
  # registry key — safe to interpolate into the config name.
  def purchase_webhook_secret
    key = "PURCHASE_WEBHOOK_SECRET_#{params[:provider].to_s.upcase}"
    secret = GlobalConfigService.load(key, nil).to_s
    Rails.logger.warn("Purchase webhook: refused — #{key} is not configured") if secret.blank?
    secret
  end

  def valid_purchase_signature?(secret, provided)
    expected = "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, request.raw_post)}"
    ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end

  def reject_purchase_signature!(reason)
    Webhooks::PurchaseAuditLogger.emit(
      provider: params[:provider].to_s,
      signature_valid: false,
      result_status: 'error',
      latency_ms: 0,
      reason: reason
    )
    error_response(
      ApiErrorCodes::INVALID_SIGNATURE,
      'Purchase webhook signature invalid',
      status: :unauthorized
    )
  end
end
