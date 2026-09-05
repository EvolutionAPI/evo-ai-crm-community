# frozen_string_literal: true

require 'rails_helper'

# Per-platform coverage for the CRM-483 verifier registry: each platform
# authenticates with its own scheme (Hotmart static token in a header, Kiwify
# Ed25519 asymmetric signature, Cakto shared token inside the body), and the
# concern must delegate to the right verifier while Virtu's house HMAC keeps
# working untouched (covered in purchases_spec.rb). Fixtures are synthetic —
# the schemes come from the public docs; swap in real delivery fixtures when a
# test account lands.
RSpec.describe 'Api::V1::Webhooks::PurchasesController per-platform verification', type: :request do
  RSpec::Matchers.define_negated_matcher :not_change, :change

  let!(:user) { User.create!(name: 'Webhook User', email: "purchase-#{SecureRandom.hex(4)}@example.com") }
  let!(:pipeline) { Pipeline.create!(name: "Compras #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user) }
  let!(:entry_stage) { pipeline.pipeline_stages.create!(name: 'Compra recebida', position: 1) }

  def registered_url(provider, secret)
    values = { 'evo_tenant' => '', 'pipeline_id' => pipeline.id.to_s, 'product' => '' }
    query = values.reject { |_key, value| value.blank? }
    query['d'] = Webhooks::PurchaseDestinationMac.mint(secret, provider, values)
    "/api/v1/webhooks/purchases/#{provider}?#{query.to_query}"
  end

  def stub_secret(provider, value)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load)
      .with("PURCHASE_WEBHOOK_SECRET_#{provider.upcase}", nil).and_return(value)
  end

  # The account's own destination-MAC secret (PurchaseWebhookSignatureConcern).
  # Layered on top of stub_secret, so call it AFTER.
  def stub_destination_secret(value)
    allow(GlobalConfigService).to receive(:load)
      .with(Webhooks::PurchaseDestinationMac::SECRET_KEY, nil).and_return(value)
  end

  def json_response
    response.parsed_body
  end

  before { Rails.cache.clear }

  describe 'hotmart (static hottok header)' do
    let(:hottok) { 'hotmart-account-token-123' }
    let(:payload) do
      {
        id: 'evt-1', event: 'PURCHASE_APPROVED',
        data: {
          product: { name: 'Curso Y' },
          buyer: { name: 'João Comprador', email: 'joao@cliente.com', checkout_phone: '11988887777' },
          purchase: { transaction: 'HP-001', status: 'APPROVED', price: { value: 497.0, currency_value: 'BRL' } }
        }
      }
    end

    before { stub_secret('hotmart', hottok) }

    it 'captures an approved purchase into contact + entry-stage card' do
      expect do
        post registered_url('hotmart', hottok), params: payload.to_json,
                                                headers: { 'X-Hotmart-Hottok' => hottok, 'Content-Type' => 'application/json' }
      end.to change(Contact, :count).by(1).and change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:created)
      item = PipelineItem.order(created_at: :desc).first
      expect(item.pipeline_stage_id).to eq(entry_stage.id)
    end

    it 'refuses a wrong token with 401 and captures nothing' do
      expect do
        post registered_url('hotmart', hottok), params: payload.to_json,
                                                headers: { 'X-Hotmart-Hottok' => 'wrong', 'Content-Type' => 'application/json' }
      end.to not_change(Contact, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a missing token with 401' do
      post registered_url('hotmart', hottok), params: payload.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses everything with 401 when no credential is configured' do
      stub_secret('hotmart', nil)
      post registered_url('hotmart', hottok), params: payload.to_json,
                                              headers: { 'X-Hotmart-Hottok' => hottok, 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not duplicate contact or card on redelivery' do
      2.times do
        post registered_url('hotmart', hottok), params: payload.to_json,
                                                headers: { 'X-Hotmart-Hottok' => hottok, 'Content-Type' => 'application/json' }
      end
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'status')).to eq('duplicate')
    end

    # Hotmart's top-level `id` is the DELIVERY id, not the order id: mapping it
    # silently would mint a second card per redelivery. It stays a last resort,
    # and a loud one.
    it 'warns when it has to fall back to the generic id' do
      allow(Rails.logger).to receive(:warn).and_call_original
      no_transaction = payload.deep_merge(data: { purchase: { transaction: nil } })

      post registered_url('hotmart', hottok), params: no_transaction.to_json,
                                              headers: { 'X-Hotmart-Hottok' => hottok, 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:created)
      expect(Rails.logger).to have_received(:warn).with(/hotmart.*generic `id`/m)
    end

    it 'acks a non-approved event as ignored without creating anything' do
      refund = payload.deep_merge(event: 'PURCHASE_REFUNDED', data: { purchase: { status: 'REFUNDED' } })
      expect do
        post registered_url('hotmart', hottok), params: refund.to_json,
                                                headers: { 'X-Hotmart-Hottok' => hottok, 'Content-Type' => 'application/json' }
      end.to not_change(Contact, :count)

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'status')).to eq('ignored')
    end
  end

  describe 'kiwify (Ed25519 prehashed signature)' do
    let(:signing_key) { OpenSSL::PKey.generate_key('ED25519') }
    let(:public_key_b64) { Base64.strict_encode64(signing_key.raw_public_key) }
    let(:payload) do
      {
        order_id: 'KW-001', order_status: 'paid', webhook_event_type: 'order_approved',
        Customer: { full_name: 'Ana Compradora', email: 'ana@cliente.com', mobile: '+5511977776666' },
        Product: { product_name: 'Curso Z' },
        Commissions: { charge_amount: 197.0, currency: 'BRL' }
      }
    end
    let(:raw_body) { payload.to_json }
    let(:destination_secret) { 'account-destination-secret' }

    before do
      stub_secret('kiwify', public_key_b64)
      stub_destination_secret(destination_secret)
    end

    def kiwify_headers(body, key: signing_key, timestamp: (Time.current.to_f * 1000).round.to_s, path: nil)
      message = "#{path || '/api/v1/webhooks/purchases/kiwify'}:POST:#{body}:#{timestamp}"
      signature = key.sign(nil, OpenSSL::Digest::SHA256.digest(message))
      {
        'x-kiwify-digital-signature' => Base64.urlsafe_encode64(signature, padding: false),
        'x-kiwify-timestamp' => timestamp,
        'Content-Type' => 'application/json'
      }
    end

    it 'captures an approved order signed with the account key' do
      expect do
        post registered_url('kiwify', destination_secret), params: raw_body, headers: kiwify_headers(raw_body)
      end.to change(Contact, :count).by(1).and change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'refuses a signature from another key with 401' do
      other_key = OpenSSL::PKey.generate_key('ED25519')
      post registered_url('kiwify', destination_secret),
           params: raw_body, headers: kiwify_headers(raw_body, key: other_key)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a stale timestamp with 401' do
      stale = ((Time.current.to_f - 600) * 1000).round.to_s
      post registered_url('kiwify', destination_secret),
           params: raw_body, headers: kiwify_headers(raw_body, timestamp: stale)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a missing signature with 401' do
      post registered_url('kiwify', destination_secret), params: raw_body, headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a non-numeric timestamp with 401' do
      post registered_url('kiwify', destination_secret),
           params: raw_body, headers: kiwify_headers(raw_body, timestamp: 'not-a-timestamp')
      expect(response).to have_http_status(:unauthorized)
    end

    # The doc says only "{url_path}" and the registered URL carries the
    # destination query; a signature over the full path must verify too, or
    # every delivery 401s on a reading of the doc we cannot confirm yet.
    it 'accepts a signature taken over the full path, query string included' do
      url = registered_url('kiwify', destination_secret)
      expect do
        post url, params: raw_body, headers: kiwify_headers(raw_body, path: url)
      end.to change(Contact, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'refuses with 401 (never 500) when the configured credential is not an Ed25519 key' do
      rsa_pem = OpenSSL::PKey::RSA.new(2048).public_key.to_pem
      stub_secret('kiwify', rsa_pem)
      post registered_url('kiwify', destination_secret), params: raw_body, headers: kiwify_headers(raw_body)
      expect(response).to have_http_status(:unauthorized)
    end

    # AC6: the platform credential is PUBLIC — a `d` minted from it must never
    # authenticate a destination, or anyone holding the key redirects deliveries.
    it 'refuses a destination MAC forged with the public key, even on a validly-signed delivery' do
      forged_url = registered_url('kiwify', public_key_b64)
      post forged_url, params: raw_body, headers: kiwify_headers(raw_body)
      expect(response).to have_http_status(:unauthorized)
    end

    context 'without a destination secret configured' do
      before { stub_destination_secret(nil) }

      it 'refuses even a validly-signed delivery — there is no fallback for a public credential' do
        post registered_url('kiwify', public_key_b64), params: raw_body, headers: kiwify_headers(raw_body)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'does not duplicate contact or card on redelivery' do
      2.times do
        post registered_url('kiwify', destination_secret), params: raw_body, headers: kiwify_headers(raw_body)
      end
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'status')).to eq('duplicate')
    end
  end

  describe 'cakto (shared token inside the body)' do
    let(:token) { 'cakto-webhook-token-123' }
    let(:payload) do
      {
        secret: token, event: 'purchase_approved',
        data: {
          id: 'CK-001', status: 'paid', amount: 97.0,
          customer: { name: 'Bia Compradora', email: 'bia@cliente.com', phone: '21966665555' },
          product: { name: 'Curso W' }
        }
      }
    end

    before { stub_secret('cakto', token) }

    it 'captures an approved purchase carrying the right body token' do
      expect do
        post registered_url('cakto', token), params: payload.to_json, headers: { 'Content-Type' => 'application/json' }
      end.to change(Contact, :count).by(1).and change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'refuses a wrong body token with 401' do
      post registered_url('cakto', token), params: payload.merge(secret: 'wrong').to_json,
                                           headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a missing body token with 401' do
      post registered_url('cakto', token), params: payload.except(:secret).to_json,
                                           headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not duplicate contact or card on redelivery' do
      2.times do
        post registered_url('cakto', token), params: payload.to_json, headers: { 'Content-Type' => 'application/json' }
      end
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'status')).to eq('duplicate')
    end

    it 'acks a non-approved event as ignored' do
      refund = payload.merge(event: 'refund').deep_merge(data: { status: 'refunded' })
      post registered_url('cakto', token), params: refund.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'status')).to eq('ignored')
    end
  end

  # The account's destination secret is introduced by CRM-483; Hotmart stands in
  # for every private-credential platform. Setting it must NOT invalidate the
  # URLs the account already registered — that would stop a working capture the
  # day the account adds Kiwify (which requires the secret), with no signal
  # beyond an audit row nobody reads.
  describe 'destination MAC key on a private-credential platform' do
    let(:hottok) { 'hotmart-account-token-123' }
    let(:destination_secret) { 'account-destination-secret' }
    let(:payload) do
      {
        id: 'evt-9', event: 'PURCHASE_APPROVED',
        data: {
          product: { name: 'Curso Y' },
          buyer: { name: 'Duda Compradora', email: 'duda@cliente.com' },
          purchase: { transaction: 'HP-009', status: 'APPROVED', price: { value: 97.0, currency_value: 'BRL' } }
        }
      }
    end

    def post_hotmart(url)
      post url, params: payload.to_json,
                headers: { 'X-Hotmart-Hottok' => hottok, 'Content-Type' => 'application/json' }
    end

    before do
      stub_secret('hotmart', hottok)
      stub_destination_secret(destination_secret)
    end

    it 'accepts a URL minted with the account destination secret' do
      expect { post_hotmart(registered_url('hotmart', destination_secret)) }.to change(Contact, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it 'still accepts a pre-split URL minted with the platform credential' do
      expect { post_hotmart(registered_url('hotmart', hottok)) }.to change(Contact, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it 'refuses a URL minted with neither' do
      expect { post_hotmart(registered_url('hotmart', 'not-a-key-of-this-account')) }.to not_change(Contact, :count)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'cross-platform isolation' do
    it "one platform's missing credential never affects another" do
      stub_secret('hotmart', nil)
      allow(GlobalConfigService).to receive(:load)
        .with('PURCHASE_WEBHOOK_SECRET_CAKTO', nil).and_return('cakto-token')

      post registered_url('hotmart', 'x'), params: '{}', headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)

      payload = { secret: 'cakto-token', event: 'purchase_approved',
                  data: { id: 'CK-9', status: 'paid', customer: { email: 'iso@cliente.com' } } }
      post registered_url('cakto', 'cakto-token'), params: payload.to_json,
                                                   headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:created)
    end
  end
end
