# frozen_string_literal: true

# Ingress for ERP-pushed bulk product imports (EVO-1735 S3.0 — third
# leaf of umbrella EVO-1555). Authenticated via HMAC SHA-256 in
# `ErpWebhookSignatureConcern`; payload routed through a per-provider
# adapter to the canonical `Products::BulkImporter` shape, so this
# endpoint never duplicates bulk logic — it converts and delegates.
#
# Inherits `ActionController::API` directly (not `Api::V1::BaseController`)
# because:
#   * authentication is HMAC, not the apikey + RBAC chain of BaseController
#   * the locale `around_action` is irrelevant on machine-to-machine ingress
#   * BaseController's response shape (`ApiResponseHelper`) is still wanted
#     and is mixed in explicitly below
#
# When the enterprise overlay is loaded, idempotency is wired via the
# `Evo::Enterprise::Licensing::Idempotent` concern (around_action,
# `X-Idempotency-Key` header required, Postgres-backed replay). In
# community-only deploys the constant is undefined and the include is
# skipped — idempotency degrades to no-op, which matches Decision 14 of
# the tech-spec.
class Api::V1::Webhooks::ErpController < ActionController::API
  include ApiResponseHelper
  include ErpWebhookSignatureConcern

  if defined?(Evo::Enterprise::Licensing::Idempotent)
    include Evo::Enterprise::Licensing::Idempotent
    # Static scope — the request_hash (SHA-256 of body) already
    # discriminates between providers in practice. A per-provider scope
    # would require overriding `idempotency_scope!` instance-side; the
    # static form is simpler and the collision space is negligible.
    idempotency_scope 'webhook:erp'
  end

  # Provider lookup runs BEFORE signature verification so that an unknown
  # provider returns 404 instead of 401 (AC3). Provider names are public
  # surface — they live in the URL path — so the small taxonomy disclosure
  # is acceptable in exchange for an honest error code.
  before_action :check_provider_known!
  before_action :verify_erp_signature!

  def receive
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      payload = JSON.parse(request.raw_post)
    rescue JSON::ParserError
      return emit_and_render_error(:invalid_json, started_at)
    end

    begin
      bulk_params = @adapter_klass.new.to_bulk_params(payload)
    rescue Webhooks::ErpAdapters::MappingError => e
      return emit_and_render_error(:mapping, started_at, details: e.errors)
    end

    raw_items = bulk_params[:products] || bulk_params['products'] || []
    # Normalize keys at the trust boundary — adapters may return either
    # string- or symbol-keyed hashes, and Products::BulkImporter's
    # pre_validate_items reads via symbol (`raw_item[:sku]`).
    items = raw_items.map { |i| i.is_a?(Hash) ? i.deep_symbolize_keys : i }

    if items.size > Products::BulkImporter::MAX_ITEMS
      return emit_and_render_error(
        :bulk_limit,
        started_at,
        details: { max: Products::BulkImporter::MAX_ITEMS, received: items.size }
      )
    end

    begin
      created = Products::BulkImporter.new(items, dry_run: false).call
    rescue Products::BulkImporter::BulkImportError => e
      return emit_and_render_error(:validation, started_at, details: e.errors_payload)
    end

    emit_audit(
      signature_valid: true,
      idempotency_hit: false,
      items_count: created.size,
      result_status: 'success',
      latency_ms: elapsed_ms(started_at)
    )

    success_response(
      data: ProductSerializer.serialize_collection(created.map(&:reload)),
      meta: { created: created.size, updated: 0, skipped: 0 },
      message: "#{created.size} products created successfully",
      status: :created
    )
  end

  private

  def check_provider_known!
    @adapter_klass = Webhooks::ErpAdapters.lookup(params[:provider])
    return if @adapter_klass

    Webhooks::ErpAuditLogger.emit(
      provider: params[:provider].to_s,
      signature_valid: false,
      idempotency_hit: false,
      items_count: 0,
      result_status: 'error',
      latency_ms: 0,
      reason: :unknown_provider
    )
    code, message, status = ERROR_KINDS.fetch(:unknown_provider)
    error_response(code, message, status: status)
  end

  def emit_and_render_error(kind, started_at, details: nil)
    code, message, status = ERROR_KINDS.fetch(kind)
    emit_audit(
      signature_valid: true,
      idempotency_hit: false,
      items_count: 0,
      result_status: 'error',
      latency_ms: elapsed_ms(started_at),
      reason: kind
    )
    error_response(code, message, details: details, status: status)
  end

  ERROR_KINDS = {
    unknown_provider: [ApiErrorCodes::UNKNOWN_PROVIDER, 'Provider not registered', :not_found],
    invalid_json:     [ApiErrorCodes::MAPPING_ERROR,    'Invalid JSON payload',   :unprocessable_entity],
    mapping:          [ApiErrorCodes::MAPPING_ERROR,    'Mapping failed',         :unprocessable_entity],
    bulk_limit:       [ApiErrorCodes::LIMIT_EXCEEDED,   "Bulk import exceeds maximum of #{Products::BulkImporter::MAX_ITEMS} items per request", :unprocessable_entity],
    validation:       [ApiErrorCodes::VALIDATION_ERROR, 'Bulk import failed; no products were created', :unprocessable_entity]
  }.freeze

  def emit_audit(payload)
    Webhooks::ErpAuditLogger.emit(payload.merge(provider: params[:provider].to_s))
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
