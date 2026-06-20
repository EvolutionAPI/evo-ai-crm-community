# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Webhooks::ErpController#receive', type: :request do
  let(:secret) { 'test-erp-secret-123' }
  let(:provider) { 'noop' }
  let(:url) { "/api/v1/webhooks/erp/#{provider}" }
  let(:payload_hash) { { products: [valid_item(1)] } }
  let(:raw_body) { payload_hash.to_json }
  let(:valid_signature) { "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, raw_body)}" }
  let(:auth_headers) { { 'X-Evo-Signature' => valid_signature, 'Content-Type' => 'application/json' } }

  def valid_item(idx)
    {
      name: "Webhook Product #{idx}",
      kind: 'physical',
      sku: "ERP-#{idx}-#{SecureRandom.hex(3)}"
    }
  end

  def sig_for(body, sec = secret)
    "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), sec, body)}"
  end

  before do
    Rails.cache.clear
    # Defensive — `spec/lib/webhooks/erp_adapters_spec.rb` clears the
    # registry between examples, and depending on test order :noop may
    # be missing by the time we run. Re-registering is idempotent.
    Webhooks::ErpAdapters.register(:noop, Webhooks::ErpAdapters::NoopAdapter)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load)
      .with('ERP_WEBHOOK_SECRET_NOOP', nil).and_return(secret)
    allow(Webhooks::ErpAuditLogger).to receive(:emit).and_call_original
  end

  context 'AC1 — happy path' do
    it 'creates products via Products::BulkImporter and returns 201' do
      expect do
        post url, params: raw_body, headers: auth_headers
      end.to change(Product, :count).by(1)

      expect(response).to have_http_status(:created)
      parsed = response.parsed_body
      expect(parsed['success']).to be(true)
      expect(parsed['data'].size).to eq(1)
      expect(parsed['meta']['created']).to eq(1)
      expect(parsed['message']).to match(/1 products created/)
    end

    it 'emits a success audit record with the expected shape' do
      post url, params: raw_body, headers: auth_headers

      expect(Webhooks::ErpAuditLogger).to have_received(:emit).with(
        hash_including(
          provider: 'noop',
          signature_valid: true,
          idempotency_hit: false,
          items_count: 1,
          result_status: 'success'
        )
      )
    end
  end

  context 'AC2 — missing or invalid signature' do
    it 'returns 401 INVALID_SIGNATURE when the header is missing' do
      # NOTE: do not stub `JSON.parse` here — it intercepts the parser
      # used by `response.parsed_body` and makes assertions on the
      # rendered error JSON unreadable. The "body was not parsed" intent
      # is already covered by `BulkImporter` never being instantiated.
      expect(Products::BulkImporter).not_to receive(:new)

      post url, params: raw_body, headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']['code']).to eq('INVALID_SIGNATURE')
    end

    it 'returns 401 INVALID_SIGNATURE when the header lacks the sha256= prefix' do
      expect(Products::BulkImporter).not_to receive(:new)

      post url,
           params: raw_body,
           headers: { 'X-Evo-Signature' => 'bogus', 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']['code']).to eq('INVALID_SIGNATURE')
    end

    it 'returns 401 INVALID_SIGNATURE when the HMAC does not match the body' do
      expect(Products::BulkImporter).not_to receive(:new)

      bad_sig = "sha256=#{'0' * 64}"
      post url,
           params: raw_body,
           headers: { 'X-Evo-Signature' => bad_sig, 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']['code']).to eq('INVALID_SIGNATURE')
    end

    it 'emits a 401 audit record with signature_valid: false (AC9 coverage for the 401 path)' do
      post url, params: raw_body, headers: { 'Content-Type' => 'application/json' }

      expect(Webhooks::ErpAuditLogger).to have_received(:emit).with(
        hash_including(
          provider: 'noop',
          signature_valid: false,
          result_status: 'error',
          reason: :malformed,
          latency_ms: 0
        )
      )
    end

    it 'returns 401 when the configured secret is blank' do
      allow(GlobalConfigService).to receive(:load)
        .with('ERP_WEBHOOK_SECRET_NOOP', nil).and_return(nil)

      post url, params: raw_body, headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::ErpAuditLogger).to have_received(:emit).with(
        hash_including(signature_valid: false, reason: :secret_missing)
      )
    end
  end

  context 'AC3 — unknown provider' do
    it 'returns 404 UNKNOWN_PROVIDER before signature verification' do
      expect(Products::BulkImporter).not_to receive(:new)
      # No ERP_WEBHOOK_SECRET_BLING configured — provider lookup must
      # short-circuit ahead of `verify_erp_signature!`.
      expect(GlobalConfigService).not_to receive(:load).with('ERP_WEBHOOK_SECRET_BLING', nil)

      post '/api/v1/webhooks/erp/bling',
           params: { products: [] }.to_json,
           headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']['code']).to eq('UNKNOWN_PROVIDER')
    end

    it 'emits an audit record with reason: :unknown_provider on the 404 path' do
      post '/api/v1/webhooks/erp/bling',
           params: { products: [] }.to_json,
           headers: { 'Content-Type' => 'application/json' }

      expect(Webhooks::ErpAuditLogger).to have_received(:emit).with(
        hash_including(
          provider: 'bling',
          signature_valid: false,
          result_status: 'error',
          reason: :unknown_provider
        )
      )
    end
  end

  context 'AC4 — mapping error' do
    let(:fake_adapter) do
      Class.new do
        def to_bulk_params(_payload)
          raise Webhooks::ErpAdapters::MappingError.new(
            errors: [{ index: 0, raw_payload_key: 'items', message: 'missing' }]
          )
        end
      end
    end

    before do
      Webhooks::ErpAdapters.register(:erp_fake, fake_adapter)
      allow(GlobalConfigService).to receive(:load)
        .with('ERP_WEBHOOK_SECRET_ERP_FAKE', nil).and_return(secret)
    end

    after { Webhooks::ErpAdapters.clear! && Webhooks::ErpAdapters.register(:noop, Webhooks::ErpAdapters::NoopAdapter) }

    it 'returns 422 MAPPING_ERROR with indexed details' do
      expect(Products::BulkImporter).not_to receive(:new)

      body = { whatever: true }.to_json
      post '/api/v1/webhooks/erp/erp_fake',
           params: body,
           headers: { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_entity)
      parsed = response.parsed_body
      expect(parsed['error']['code']).to eq('MAPPING_ERROR')
      expect(parsed['error']['details']).to eq(
        [{ 'index' => 0, 'raw_payload_key' => 'items', 'message' => 'missing' }]
      )
    end

    # Note: a request with malformed JSON and Content-Type:
    # application/json is rejected by Rails middleware
    # (ActionDispatch::Http::Parameters::ParseError → 400) BEFORE the
    # controller runs, so the controller's `rescue JSON::ParserError`
    # is defense-in-depth only. Not exercised via the request pipeline
    # because real ERPs always send application/json.
  end

  context 'AC5 — adapter contract is consumable by BulkImporter' do
    it 'NoopAdapter#to_bulk_params produces a Hash the importer accepts verbatim' do
      payload = { 'products' => [valid_item(1).stringify_keys] }
      bulk_params = Webhooks::ErpAdapters::NoopAdapter.new.to_bulk_params(payload)

      expect(bulk_params).to be_a(Hash)
      expect(bulk_params[:products]).to be_an(Array)

      # Instantiating with the adapter output should not raise.
      expect { Products::BulkImporter.new(bulk_params[:products], dry_run: false) }.not_to raise_error
    end
  end

  context 'AC6 — idempotency (overlay-gated)', if: defined?(Evo::Enterprise::Licensing::Idempotent) do
    it 'serves the cached response on replay without re-invoking the importer' do
      headers_with_key = auth_headers.merge('X-Idempotency-Key' => SecureRandom.hex)

      expect(Products::BulkImporter).to receive(:new).once.and_call_original

      2.times { post url, params: raw_body, headers: headers_with_key }
      expect(response).to have_http_status(:created)
    end
  end

  context 'AC6 — idempotency (community fallback)', unless: defined?(Evo::Enterprise::Licensing::Idempotent) do
    let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(memory_cache) }

    it 'replays the cached response on second call with the same X-Idempotency-Key' do
      idem = SecureRandom.hex
      headers = auth_headers.merge('X-Idempotency-Key' => idem)

      expect(Products::BulkImporter).to receive(:new).once.and_call_original

      expect { post url, params: raw_body, headers: headers }.to change(Product, :count).by(1)
      first_body = response.parsed_body
      expect(response).to have_http_status(:created)

      expect { post url, params: raw_body, headers: headers }.not_to change(Product, :count)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq(first_body)
    end

    it 'falls back to SHA256(raw_post) when no X-Idempotency-Key header is provided' do
      expect(Products::BulkImporter).to receive(:new).once.and_call_original

      expect { post url, params: raw_body, headers: auth_headers }.to change(Product, :count).by(1)
      expect { post url, params: raw_body, headers: auth_headers }.not_to change(Product, :count)
    end

    it 'emits an audit record with idempotency_hit: true on replay' do
      idem = SecureRandom.hex
      headers = auth_headers.merge('X-Idempotency-Key' => idem)

      post url, params: raw_body, headers: headers
      post url, params: raw_body, headers: headers

      expect(Webhooks::ErpAuditLogger).to have_received(:emit).with(
        hash_including(idempotency_hit: true, result_status: 'success', items_count: 1)
      ).at_least(:once)
    end

    it 'does NOT cache failed responses — they remain retryable' do
      Product.create!(name: 'Pre', kind: 'physical', sku: 'ERP-RETRY-001')
      idem = SecureRandom.hex
      body = { products: [{ name: 'X', kind: 'physical', sku: 'ERP-RETRY-001' }] }.to_json
      headers = { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json', 'X-Idempotency-Key' => idem }

      post url, params: body, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(memory_cache.read("erp_webhook:#{provider}:#{idem}")).to be_nil
    end
  end

  context 'AC7 — validation error from importer' do
    it 'maps BulkImportError#errors_payload onto error_response details' do
      Product.create!(name: 'Pre-existing', kind: 'physical', sku: 'ERP-DUP-001')
      body = { products: [{ name: 'Dup', kind: 'physical', sku: 'ERP-DUP-001' }] }.to_json

      expect do
        post url,
             params: body,
             headers: { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json' }
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      parsed = response.parsed_body
      expect(parsed['error']['code']).to eq('VALIDATION_ERROR')
      offender = parsed['error']['details'].find { |d| d['sku'] == 'ERP-DUP-001' }
      expect(offender).to be_present
      expect(offender['errors']['sku'].join(' ')).to match(/taken/i)
    end
  end

  context 'AC8 — Rack::Attack throttle' do
    around do |example|
      original_enabled = Rack::Attack.enabled
      Rack::Attack.enabled = true
      Rack::Attack.reset!
      example.run
      Rack::Attack.enabled = original_enabled
      Rack::Attack.reset!
    end

    it 'registers the api/v1/webhooks/erp throttle with sane defaults' do
      throttle = Rack::Attack.throttles['api/v1/webhooks/erp']
      expect(throttle).to be_present
      expect(throttle.limit).to eq(10)
      expect(throttle.period).to eq(60)
    end

    context 'when driven via Rack::MockRequest' do
      let(:downstream_app) { ->(_env) { [200, {}, ['ok']] } }
      let(:mock_session) { Rack::MockRequest.new(Rack::Attack.new(downstream_app)) }

      around do |example|
        original_store = Rack::Attack.cache.store
        Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
        example.run
        Rack::Attack.cache.store = original_store
      end

      it 'the 11th request for the same provider returns 429 regardless of signature' do
        # AC8 — bucket is keyed by provider, so distinct signatures all
        # share the same throttle counter. Without this guarantee a
        # compromised provider could be flooded with arbitrarily many
        # well-formed but distinct payloads.
        10.times do |i|
          mock_session.post('/api/v1/webhooks/erp/noop', { 'HTTP_X_EVO_SIGNATURE' => "sha256=#{i}" })
        end
        last = mock_session.post('/api/v1/webhooks/erp/noop', { 'HTTP_X_EVO_SIGNATURE' => 'sha256=ff' })

        expect(last.status).to eq(429)
      end

      it 'distinct providers land in distinct buckets' do
        10.times { mock_session.post('/api/v1/webhooks/erp/noop') }
        other = mock_session.post('/api/v1/webhooks/erp/other')

        expect(other.status).to eq(200)
      end
    end
  end

  context 'bulk limit enforcement (S3-AC8 ceiling parity with S1)' do
    it 'returns 422 LIMIT_EXCEEDED when the payload carries more than MAX_ITEMS' do
      expect(Products::BulkImporter).not_to receive(:new)

      oversized = { products: Array.new(Products::BulkImporter::MAX_ITEMS + 1) { |i| valid_item(i) } }
      body = oversized.to_json

      expect do
        post url,
             params: body,
             headers: { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json' }
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      parsed = response.parsed_body
      expect(parsed['error']['code']).to eq('LIMIT_EXCEEDED')
      expect(parsed['error']['details']).to include(
        'max' => Products::BulkImporter::MAX_ITEMS,
        'received' => Products::BulkImporter::MAX_ITEMS + 1
      )
    end
  end

  context 'string-keyed payload normalization (AC5 parity with S1)' do
    it 'detects duplicated SKUs within a batch even when JSON parsed into string keys' do
      # NoopAdapter passes JSON.parse output verbatim (string-keyed hashes).
      # Without normalization the symbol-keyed `raw_item[:sku]` lookup in
      # Products::BulkImporter#pre_validate_items returns nil and the
      # intra-batch dup check silently misses.
      body = {
        products: [
          { name: 'Dup A', kind: 'physical', sku: 'ERP-SAME-001' },
          { name: 'Dup B', kind: 'physical', sku: 'ERP-SAME-001' }
        ]
      }.to_json

      expect do
        post url,
             params: body,
             headers: { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json' }
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      parsed = response.parsed_body
      expect(parsed['error']['code']).to eq('VALIDATION_ERROR')
      offender = parsed['error']['details'].find { |d| d['index'] == 1 }
      expect(offender).to be_present
      expect(offender['errors']['sku'].join(' ')).to match(/duplicated within batch/i)
    end
  end

  context 'AC10 — atomicity (rollback on validation error)' do
    it 'persists zero products + zero taggings + zero tags when any item fails validation' do
      products_before = Product.count
      taggings_before = ActsAsTaggableOn::Tagging.count
      tags_before     = ActsAsTaggableOn::Tag.count

      body = {
        products: [
          { name: 'OK', kind: 'physical', labels: %w[promo s3-rollback-marker] },
          { kind: 'physical' } # name blank → invalid
        ]
      }.to_json

      post url,
           params: body,
           headers: { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Product.count).to eq(products_before)
      expect(ActsAsTaggableOn::Tagging.count).to eq(taggings_before)
      expect(ActsAsTaggableOn::Tag.count).to eq(tags_before)
      expect(ActsAsTaggableOn::Tag.where(name: 's3-rollback-marker')).to be_empty
    end
  end
end
