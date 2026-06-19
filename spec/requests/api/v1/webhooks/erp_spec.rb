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
    it 'returns 401 without a body when the header is missing' do
      expect(Products::BulkImporter).not_to receive(:new)
      expect(JSON).not_to receive(:parse).with(raw_body)

      post url, params: raw_body, headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to be_empty
    end

    it 'returns 401 when the header lacks the sha256= prefix' do
      expect(Products::BulkImporter).not_to receive(:new)

      post url,
           params: raw_body,
           headers: { 'X-Evo-Signature' => 'bogus', 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 when the HMAC does not match the body' do
      expect(Products::BulkImporter).not_to receive(:new)

      bad_sig = "sha256=#{'0' * 64}"
      post url,
           params: raw_body,
           headers: { 'X-Evo-Signature' => bad_sig, 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
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
    it 'returns 404 UNKNOWN_PROVIDER and never invokes the importer' do
      allow(GlobalConfigService).to receive(:load)
        .with('ERP_WEBHOOK_SECRET_BLING', nil).and_return(secret)
      expect(Products::BulkImporter).not_to receive(:new)

      body = { products: [] }.to_json
      post '/api/v1/webhooks/erp/bling',
           params: body,
           headers: { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']['code']).to eq('UNKNOWN_PROVIDER')
    end
  end

  context 'AC4 — mapping error' do
    let(:fake_adapter) do
      Class.new do
        def to_bulk_params(_payload)
          raise Webhooks::ErpAdapters::MappingError.new(
            errors: [{ index: 0, key: 'items', message: 'missing' }]
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
        [{ 'index' => 0, 'key' => 'items', 'message' => 'missing' }]
      )
    end

    it 'returns 422 MAPPING_ERROR for invalid JSON' do
      garbage = '{not-json'
      post url,
           params: garbage,
           headers: { 'X-Evo-Signature' => sig_for(garbage), 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']['code']).to eq('MAPPING_ERROR')
    end
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

  context 'AC6 — idempotency (community no-op)', unless: defined?(Evo::Enterprise::Licensing::Idempotent) do
    it 'is structurally a no-op when the enterprise overlay is absent', skip: 'enterprise overlay not loaded' do
      # Documented gap: the Idempotent concern lives in
      # evo-crm-enterprise/evo-enterprise-licensing-ruby and is not part of
      # the community Gemfile. AC6 is enforced by the overlay test suite.
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

      it 'the 11th replay (same signature) returns 429' do
        env = { 'HTTP_X_EVO_SIGNATURE' => 'sha256=deadbeef' }

        10.times { mock_session.post('/api/v1/webhooks/erp/noop', env) }
        last = mock_session.post('/api/v1/webhooks/erp/noop', env)

        expect(last.status).to eq(429)
      end

      it 'distinct signatures land in distinct buckets (by design)' do
        # Documents Decision 10 — the discriminator hashes the signature,
        # so 11 requests with 11 different signatures do NOT trigger.
        11.times do |i|
          response_status = mock_session.post(
            '/api/v1/webhooks/erp/noop',
            { 'HTTP_X_EVO_SIGNATURE' => "sha256=#{i}" }
          ).status

          expect(response_status).to eq(200)
        end
      end
    end
  end

  context 'AC10 — atomicity (rollback on validation error)' do
    it 'persists zero products + zero taggings when any item fails validation' do
      taggings_before = ActsAsTaggableOn::Tagging.count
      body = {
        products: [
          { name: 'OK', kind: 'physical', labels: %w[promo] },
          { kind: 'physical' } # name blank → invalid
        ]
      }.to_json

      expect do
        post url,
             params: body,
             headers: { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json' }
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActsAsTaggableOn::Tagging.count).to eq(taggings_before)
    end
  end
end
