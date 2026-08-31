# frozen_string_literal: true

# Auth for purchase webhooks, in two halves: `verify_purchase_signature!` is the
# platform's own scheme (per-provider verifier from the registry — HMAC, static
# token or asymmetric signature); `verify_purchase_destination!` is OUR MAC over
# the query params that pick the destination, which the platform's signature
# cannot cover. Both fail closed; the reason lives in the audit, never on the wire.
module PurchaseWebhookSignatureConcern
  extend ActiveSupport::Concern

  # Per-account secret that signs the destination query string. Shares the
  # tenant-only prefix with the per-platform credentials; "DESTINATION" can
  # never collide with a provider because providers are only reachable through
  # the registry, where no such key is ever registered.
  DESTINATION_SECRET_KEY = 'PURCHASE_WEBHOOK_SECRET_DESTINATION'

  private

  def verify_purchase_signature!
    secret = purchase_webhook_secret
    return reject_purchase_signature!(:secret_missing) if secret.blank?

    verifier = Webhooks::PurchaseAdapters.verifier_for(params[:provider])
    return reject_purchase_signature!(:verifier_missing) if verifier.nil?

    result = verifier.verify(request: request, secret: secret)
    return true if result == true

    Rails.logger.warn(
      "Purchase webhook: refused — #{result} (#{verifier.name.demodulize}). " \
      "body_size=#{request.raw_post.bytesize}"
    )
    reject_purchase_signature!(result)
  end

  # Without this, a delivery captured for one tenant/pipeline replays into any
  # other: the body — and therefore the platform's signature over it — is
  # unchanged, only the query string moves.
  def verify_purchase_destination!
    secret = purchase_destination_mac_secret
    return reject_purchase_signature!(:destination_secret_missing) if secret.blank?

    provided = request.query_parameters[Webhooks::PurchaseDestinationMac::QUERY_PARAM].to_s
    return reject_purchase_signature!(:destination_unsigned) if provided.blank?

    expected = Webhooks::PurchaseDestinationMac.mint(secret, params[:provider], request.query_parameters)
    return true if ActiveSupport::SecurityUtils.secure_compare(expected, provided)

    Rails.logger.warn('Purchase webhook: refused — destination MAC mismatch (evo_tenant/pipeline_id/product tampered?)')
    reject_purchase_signature!(:destination_mismatch)
  end

  # The destination MAC is keyed by OUR per-account secret, never by public
  # material. Legacy fallback to the platform credential survives only for
  # schemes whose credential is private (Virtu/Hotmart/Cakto) so URLs minted
  # before the split keep working; for an asymmetric scheme (Kiwify) the
  # credential is a public key — a MAC keyed by it is forgeable by anyone
  # holding it — so there is no fallback and the destination secret is required.
  def purchase_destination_mac_secret
    destination = GlobalConfigService.load(DESTINATION_SECRET_KEY, nil).to_s
    return destination if destination.present?

    verifier = Webhooks::PurchaseAdapters.verifier_for(params[:provider])
    return nil if verifier.nil? || verifier.public_credential?

    purchase_webhook_secret
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
