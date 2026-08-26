# frozen_string_literal: true

# Auth for purchase webhooks, in two halves: `verify_purchase_signature!` is the
# platform's HMAC over the body; `verify_purchase_destination!` is OUR MAC over
# the query params that pick the destination, which the platform's signature
# cannot cover. Both fail closed; the reason lives in the audit, never on the wire.
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

  # Without this, a delivery captured for one tenant/pipeline replays into any
  # other: the body — and therefore the platform's signature over it — is
  # unchanged, only the query string moves.
  def verify_purchase_destination!
    secret = purchase_webhook_secret
    return reject_purchase_signature!(:secret_missing) if secret.blank?

    provided = request.query_parameters[Webhooks::PurchaseDestinationMac::QUERY_PARAM].to_s
    return reject_purchase_signature!(:destination_unsigned) if provided.blank?

    expected = Webhooks::PurchaseDestinationMac.mint(secret, params[:provider], request.query_parameters)
    return true if ActiveSupport::SecurityUtils.secure_compare(expected, provided)

    Rails.logger.warn('Purchase webhook: refused — destination MAC mismatch (evo_tenant/pipeline_id/product tampered?)')
    reject_purchase_signature!(:destination_mismatch)
  end

  # check_provider_known! runs first, so `params[:provider]` is an allow-listed
  # registry key — safe to interpolate into the config name.
  def purchase_webhook_secret
    return @purchase_webhook_secret if defined?(@purchase_webhook_secret)

    key = "PURCHASE_WEBHOOK_SECRET_#{params[:provider].to_s.upcase}"
    @purchase_webhook_secret = GlobalConfigService.load(key, nil).to_s
    Rails.logger.warn("Purchase webhook: refused — #{key} is not configured") if @purchase_webhook_secret.blank?
    @purchase_webhook_secret
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
