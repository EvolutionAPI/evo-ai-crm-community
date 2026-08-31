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

  def json_response
    JSON.parse(response.body)
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

    before { stub_secret('kiwify', public_key_b64) }

    def kiwify_headers(body, key: signing_key, timestamp: (Time.current.to_f * 1000).round.to_s)
      message = "/api/v1/webhooks/purchases/kiwify:POST:#{body}:#{timestamp}"
      signature = key.sign(nil, OpenSSL::Digest::SHA256.digest(message))
      {
        'x-kiwify-digital-signature' => Base64.urlsafe_encode64(signature, padding: false),
        'x-kiwify-timestamp' => timestamp,
        'Content-Type' => 'application/json'
      }
    end

    it 'captures an approved order signed with the account key' do
      expect do
        post registered_url('kiwify', public_key_b64), params: raw_body, headers: kiwify_headers(raw_body)
      end.to change(Contact, :count).by(1).and change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'refuses a signature from another key with 401' do
      other_key = OpenSSL::PKey.generate_key('ED25519')
      post registered_url('kiwify', public_key_b64), params: raw_body,
                                                     headers: kiwify_headers(raw_body, key: other_key)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a stale timestamp with 401' do
      stale = ((Time.current.to_f - 600) * 1000).round.to_s
      post registered_url('kiwify', public_key_b64), params: raw_body,
                                                     headers: kiwify_headers(raw_body, timestamp: stale)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a missing signature with 401' do
      post registered_url('kiwify', public_key_b64), params: raw_body, headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not duplicate contact or card on redelivery' do
      2.times do
        post registered_url('kiwify', public_key_b64), params: raw_body, headers: kiwify_headers(raw_body)
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
