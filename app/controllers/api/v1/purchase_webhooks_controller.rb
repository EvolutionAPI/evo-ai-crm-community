# frozen_string_literal: true

# Authenticated config surface of the purchase-webhook ingress: which platforms
# exist/are configured, and the signed URL the operator registers at one. Gated
# by pipelines.update — choosing where purchases land IS pipeline management.
# (The unauthenticated delivery ingress lives in Webhooks::PurchasesController.)
class Api::V1::PurchaseWebhooksController < Api::V1::BaseController
  require_permissions({
    providers: 'pipelines.update',
    url: 'pipelines.update'
  })

  ERROR_RESPONSES = {
    unknown_provider: [ApiErrorCodes::UNKNOWN_PROVIDER, 'Provider not registered', :not_found],
    pipeline_not_found: [ApiErrorCodes::VALIDATION_ERROR, 'Pipeline not found', :unprocessable_entity],
    pipeline_without_stages: [ApiErrorCodes::VALIDATION_ERROR,
                              'Pipeline has no stages — the lead would have no entry stage', :unprocessable_entity],
    credential_missing: [ApiErrorCodes::VALIDATION_ERROR,
                         'No credential configured for this platform', :unprocessable_entity],
    destination_secret_required: [ApiErrorCodes::VALIDATION_ERROR,
                                  "This platform's credential is public — configure the URL destination secret first",
                                  :unprocessable_entity]
  }.freeze

  def providers
    success_response(
      data: Webhooks::PurchaseWebhookUrl.new.providers_payload,
      message: 'Purchase webhook providers retrieved successfully'
    )
  end

  def url
    result = Webhooks::PurchaseWebhookUrl.new.mint(
      provider: params[:provider],
      pipeline_id: params[:pipeline_id],
      product: params[:product].presence
    )

    if result.error
      code, message, status = ERROR_RESPONSES.fetch(result.error)
      error_response(code, message, details: { reason: result.error.to_s.upcase }, status: status)
    else
      success_response(
        data: { url: result.url, host_kind: result.host_kind },
        message: 'Purchase webhook URL minted successfully'
      )
    end
  end
end
