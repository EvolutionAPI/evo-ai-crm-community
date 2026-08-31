# frozen_string_literal: true

# Auth for purchase webhooks, in two halves: `verify_purchase_signature!` is the
# platform's own scheme (per-provider verifier from the registry — HMAC, static
# token or asymmetric signature); `verify_purchase_destination!` is OUR MAC over
# the query params that pick the destination, which the platform's signature
# cannot cover. Both fail closed; the reason lives in the audit, never on the wire.
module PurchaseWebhookSignatureConcern
  extend ActiveSupport::Concern

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
    keys = purchase_destination_mac_keys
    return reject_purchase_signature!(:destination_secret_missing) if keys.empty?

    provided = request.query_parameters[Webhooks::PurchaseDestinationMac::QUERY_PARAM].to_s
    return reject_purchase_signature!(:destination_unsigned) if provided.blank?

    matched = keys.find { |secret| destination_mac_matches?(secret, provided) }
    if matched
      warn_legacy_destination_key(matched, keys)
      return true
    end

    Rails.logger.warn('Purchase webhook: refused — destination MAC mismatch (evo_tenant/pipeline_id/product tampered?)')
    reject_purchase_signature!(:destination_mismatch)
  end

  # Keys accepted for the destination MAC, preferred first: OUR per-account
  # secret, then the platform credential — but only for a scheme whose
  # credential is PRIVATE. Both are accepted so that setting the destination
  # secret does not silently 401 every URL the account already registered; the
  # platform-keyed MAC is exactly the CRM-320 guarantee, no weaker than before
  # the split. For an asymmetric scheme (Kiwify) the credential is a public key
  # — a MAC keyed by it is forgeable by anyone holding it — so it is never
  # accepted and the destination secret is required.
  def purchase_destination_mac_keys
    keys = [GlobalConfigService.load(Webhooks::PurchaseDestinationMac::SECRET_KEY, nil).to_s]

    verifier = Webhooks::PurchaseAdapters.verifier_for(params[:provider])
    keys << purchase_webhook_secret unless verifier.nil? || verifier.public_credential?

    keys.select(&:present?)
  end

  def destination_mac_matches?(secret, provided)
    expected = Webhooks::PurchaseDestinationMac.mint(secret, params[:provider], request.query_parameters)
    ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end

  # A URL still signed by the platform credential while the account already has
  # its own destination secret is a pre-split URL: it works, but it stops the
  # day the platform credential is rotated. Say so, or nobody re-mints it.
  def warn_legacy_destination_key(matched, keys)
    return if keys.size < 2 || matched == keys.first

    Rails.logger.warn(
      "Purchase webhook (#{params[:provider]}): destination MAC accepted on the legacy platform-credential key — " \
      're-mint the registered URL with the account destination secret'
    )
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
