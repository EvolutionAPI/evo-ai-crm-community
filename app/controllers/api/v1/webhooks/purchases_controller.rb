# frozen_string_literal: true

# Ingress for payment-platform purchase webhooks: an approved purchase becomes
# a contact + a pipeline card on the entry stage (lead capture). Authenticated
# via HMAC SHA-256 in `PurchaseWebhookSignatureConcern`; the payload is routed
# through a per-provider adapter to the canonical lead shape and delegated to
# `Webhooks::Purchases::LeadCaptureService` — the endpoint never duplicates
# capture logic.
#
# Inherits `ActionController::API` directly (not `Api::V1::BaseController`)
# for the same reasons as the ERP webhook: HMAC auth instead of the
# apikey+RBAC chain, machine-to-machine (no locale), response shape via
# `ApiResponseHelper` mixed in explicitly.
#
# Every outcome is distinct on the wire and in the audit trail — no silent
# 200 discard: unknown provider (404), bad signature (401), unmappable or
# invalid payload (422), non-approved event (200 ignored), success (201),
# redelivery (200 duplicate, idempotent by the partial UNIQUE index on
# custom_fields['purchase']).
class Api::V1::Webhooks::PurchasesController < ActionController::API
  include ApiResponseHelper
  include PurchaseWebhookSignatureConcern

  # Deliberately NOT including the enterprise Idempotent concern: it demands an
  # X-Idempotency-Key header, and payment platforms send only their own fixed
  # header set. Idempotency here is enforced at the database instead — the
  # partial UNIQUE index on custom_fields['purchase'] (provider, purchase_id) —
  # which also covers concurrent redeliveries, something a replay cache cannot.

  # Provider lookup runs BEFORE signature verification so an unknown provider
  # returns 404 instead of 401 — provider names are public surface (URL path).
  before_action :check_provider_known!
  before_action :verify_purchase_signature!

  def receive
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      payload = JSON.parse(request.raw_post)
    rescue JSON::ParserError
      return emit_and_render_error(:invalid_json, started_at)
    end

    begin
      lead = @adapter_klass.new.to_lead(payload)
    rescue Webhooks::PurchaseAdapters::MappingError => e
      return emit_and_render_error(:mapping, started_at, details: e.errors)
    end

    result = Webhooks::Purchases::LeadCaptureService.new(
      provider: params[:provider],
      lead: lead,
      pipeline_id: params[:pipeline_id],
      product_override: params[:product]
    ).perform

    render_result(result, lead, started_at)
  end

  private

  SUCCESS_STATUSES = {
    created: [:created, 'Lead captured'],
    duplicate: [:ok, 'Purchase already captured'],
    already_in_pipeline: [:ok, 'Contact already has an active card in this pipeline'],
    ignored: [:ok, 'Event ignored (not an approved purchase)']
  }.freeze

  ERROR_KINDS = {
    unknown_provider: [ApiErrorCodes::UNKNOWN_PROVIDER, 'Provider not registered', :not_found],
    invalid_json: [ApiErrorCodes::MAPPING_ERROR, 'Invalid JSON payload', :unprocessable_entity],
    mapping: [ApiErrorCodes::MAPPING_ERROR, 'Payload mapping failed', :unprocessable_entity],
    pipeline_not_found: [ApiErrorCodes::VALIDATION_ERROR, 'Destination pipeline not found or has no stages', :unprocessable_entity],
    contact_error: [ApiErrorCodes::VALIDATION_ERROR, 'Contact could not be saved', :unprocessable_entity],
    pipeline_item_error: [ApiErrorCodes::VALIDATION_ERROR, 'Pipeline card could not be created', :unprocessable_entity]
  }.freeze

  def render_result(result, lead, started_at)
    if (status, message = SUCCESS_STATUSES[result.status])
      emit_audit(
        signature_valid: true,
        result_status: result.status.to_s,
        purchase_id: lead[:purchase_id],
        latency_ms: elapsed_ms(started_at)
      )
      success_response(
        data: {
          status: result.status.to_s,
          contact_id: result.contact&.id,
          pipeline_item_id: result.pipeline_item&.id
        },
        message: message,
        status: status
      )
    else
      emit_and_render_error(result.status, started_at, details: result.details, purchase_id: lead[:purchase_id])
    end
  end

  def check_provider_known!
    @adapter_klass = Webhooks::PurchaseAdapters.lookup(params[:provider])
    return if @adapter_klass

    Webhooks::PurchaseAuditLogger.emit(
      provider: params[:provider].to_s,
      signature_valid: false,
      result_status: 'error',
      latency_ms: 0,
      reason: :unknown_provider
    )
    code, message, status = ERROR_KINDS.fetch(:unknown_provider)
    error_response(code, message, status: status)
  end

  def emit_and_render_error(kind, started_at, details: nil, purchase_id: nil)
    code, message, status = ERROR_KINDS.fetch(kind)
    emit_audit(
      signature_valid: true,
      result_status: 'error',
      purchase_id: purchase_id,
      latency_ms: elapsed_ms(started_at),
      reason: kind
    )
    error_response(code, message, details: details, status: status)
  end

  def emit_audit(payload)
    Webhooks::PurchaseAuditLogger.emit(payload.merge(provider: params[:provider].to_s))
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
