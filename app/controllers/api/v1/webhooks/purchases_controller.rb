# frozen_string_literal: true

# Ingress for payment-platform purchase webhooks: an approved purchase becomes a
# contact + a pipeline card on the entry stage. Auth is HMAC (body + destination,
# see PurchaseWebhookSignatureConcern), mapping is per-provider adapter, capture
# is LeadCaptureService. Every outcome is distinct on the wire AND in the audit.
class Api::V1::Webhooks::PurchasesController < ActionController::API
  include ApiResponseHelper
  include PurchaseWebhookSignatureConcern

  # Deliberately NOT the enterprise Idempotent concern: it demands an
  # X-Idempotency-Key header and payment platforms send only their own headers.
  # Idempotency is the partial UNIQUE index on custom_fields['purchase'] instead,
  # which also covers concurrent redeliveries — a replay cache cannot.

  # Provider lookup runs BEFORE signature verification so an unknown provider
  # returns 404 instead of 401 — provider names are public surface (URL path).
  before_action :check_provider_known!
  before_action :verify_purchase_signature!
  before_action :verify_purchase_destination!
  before_action :check_tenant_bound!

  def receive
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    payload = parse_payload
    return emit_and_render_error(:invalid_json, started_at) if payload.nil?

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
  rescue StandardError => e
    # Re-raised on purpose (the platform must retry a transient failure), but
    # never without a record: an unaudited 500 is the one shape AC2 forbids.
    emit_audit(signature_valid: true, result_status: 'error', latency_ms: elapsed_ms(started_at),
               reason: :unhandled, exception: e.class.name)
    raise
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
    tenant_unbound: [ApiErrorCodes::VALIDATION_ERROR, 'Webhook URL is not bound to an account', :unprocessable_entity],
    pipeline_not_found: [ApiErrorCodes::VALIDATION_ERROR, 'Destination pipeline not found or has no stages', :unprocessable_entity],
    contact_error: [ApiErrorCodes::VALIDATION_ERROR, 'Contact could not be saved', :unprocessable_entity],
    pipeline_item_error: [ApiErrorCodes::VALIDATION_ERROR, 'Pipeline card could not be created', :unprocessable_entity]
  }.freeze

  # A JSON array/scalar body parses fine and then dies on `payload['data']`, so
  # the shape is checked here rather than inside every adapter.
  def parse_payload
    parsed = JSON.parse(request.raw_post)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def render_result(result, lead, started_at)
    success = SUCCESS_STATUSES[result.status]
    return emit_and_render_error(result.status, started_at, details: result.details, purchase_id: lead[:purchase_id]) unless success

    status, message = success
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

  # Under the enterprise overlay every insert needs a bound tenant; unbound, the
  # contact insert dies on a NOT NULL violation deep in the stack. Refuse up front
  # so a webhook URL missing ?evo_tenant= reads as the config error it is.
  def check_tenant_bound!
    return unless defined?(Evo::Enterprise::Licensing) &&
                  Evo::Enterprise::Licensing.respond_to?(:current_tenant_id)
    return if Evo::Enterprise::Licensing.current_tenant_id.present?

    emit_and_render_error(:tenant_unbound, Process.clock_gettime(Process::CLOCK_MONOTONIC))
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
