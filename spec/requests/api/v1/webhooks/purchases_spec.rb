# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Webhooks::PurchasesController#receive', type: :request do
  RSpec::Matchers.define_negated_matcher :not_change, :change

  let(:secret) { 'test-purchase-secret-123' }
  let(:provider) { 'virtu' }
  let(:base_url) { "/api/v1/webhooks/purchases/#{provider}" }

  let!(:user) { User.create!(name: 'Webhook User', email: "purchase-#{SecureRandom.hex(4)}@example.com") }
  let!(:pipeline) { Pipeline.create!(name: "Compras #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user) }
  let!(:entry_stage) { pipeline.pipeline_stages.create!(name: 'Compra recebida', position: 1) }
  let!(:later_stage) { pipeline.pipeline_stages.create!(name: 'Onboarding', position: 2) }
  let(:url) { registered_url }

  let(:payload_hash) do
    {
      event: 'approved',
      data: {
        order_id: 'ORD-1001',
        product: 'Curso X',
        amount: 297.0,
        customer: { name: 'Maria Compradora', email: 'Maria@Cliente.com', phone: '11999998888' }
      }
    }
  end
  let(:raw_body) { payload_hash.to_json }

  # The URL an operator registers at the platform: destination params plus the
  # MAC that pins them (rake evo_purchase_webhook:url mints the same string).
  def registered_url(pipeline_id: pipeline.id, evo_tenant: nil, product: nil, prov: provider, sec: secret)
    values = { 'evo_tenant' => evo_tenant.to_s, 'pipeline_id' => pipeline_id.to_s, 'product' => product.to_s }
    query = values.reject { |_key, value| value.blank? }
    query['d'] = Webhooks::PurchaseDestinationMac.mint(sec, prov, values)
    "/api/v1/webhooks/purchases/#{prov}?#{query.to_query}"
  end

  def sig_for(body, sec = secret)
    "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), sec, body)}"
  end

  def auth_headers(body = raw_body)
    { 'X-Evo-Signature' => sig_for(body), 'Content-Type' => 'application/json' }
  end

  before do
    Rails.cache.clear
    Webhooks::PurchaseAdapters.register(:virtu, Webhooks::PurchaseAdapters::VirtuAdapter)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load)
      .with('PURCHASE_WEBHOOK_SECRET_VIRTU', nil).and_return(secret)
    allow(Webhooks::PurchaseAuditLogger).to receive(:emit).and_call_original
  end

  context 'when the provider is not in the registry' do
    it 'returns 404 UNKNOWN_PROVIDER for a provider outside the registry' do
      post "/api/v1/webhooks/purchases/nope?pipeline_id=#{pipeline.id}", params: raw_body,
                                                                         headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']['code']).to eq('UNKNOWN_PROVIDER')
    end
  end

  context 'when the signature gate rejects (fail-closed)' do
    it 'returns 401 when the secret is not configured' do
      allow(GlobalConfigService).to receive(:load)
        .with('PURCHASE_WEBHOOK_SECRET_VIRTU', nil).and_return(nil)

      post url, params: raw_body, headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']['code']).to eq('INVALID_SIGNATURE')
    end

    it 'returns 401 on signature mismatch and creates nothing' do
      expect do
        post url, params: raw_body, headers: { 'X-Evo-Signature' => sig_for(raw_body, 'wrong'),
                                               'Content-Type' => 'application/json' }
      end.not_to change(Contact, :count)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'when the destination MAC does not vouch for the query params (AC3)' do
    it 'refuses a URL carrying no destination MAC' do
      expect do
        post "#{base_url}?pipeline_id=#{pipeline.id}", params: raw_body, headers: auth_headers
      end.to not_change(Contact, :count).and not_change(PipelineItem, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a VALID delivery replayed at another pipeline (body and signature untouched)' do
      post url, params: raw_body, headers: auth_headers
      expect(response).to have_http_status(:created)

      victim = Pipeline.create!(name: "Vitima #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user)
      victim.pipeline_stages.create!(name: 'Entrada', position: 1)
      stolen_mac = url[/d=([^&]+)/, 1]

      expect do
        post "#{base_url}?pipeline_id=#{victim.id}&d=#{stolen_mac}", params: raw_body, headers: auth_headers
      end.not_to change(PipelineItem, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(victim.pipeline_items.count).to eq(0)
    end

    it 'refuses a MAC minted for a different account (evo_tenant swapped)' do
      minted = registered_url(evo_tenant: SecureRandom.uuid)
      tampered = minted.sub(/evo_tenant=[^&]+/, "evo_tenant=#{SecureRandom.uuid}")

      post tampered, params: raw_body, headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'when an approved purchase arrives (AC1)' do
    it 'creates contact + card and answers 201 created' do
      expect do
        post url, params: raw_body, headers: auth_headers
      end.to change(Contact, :count).by(1).and change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['data']['status']).to eq('created')

      contact = Contact.find(response.parsed_body['data']['contact_id'])
      expect(contact.email).to eq('maria@cliente.com')
      expect(contact.phone_number).to eq('+5511999998888')
    end

    it 'lands the card on the ENTRY stage carrying the purchase identity' do
      post url, params: raw_body, headers: auth_headers

      item = PipelineItem.find(response.parsed_body['data']['pipeline_item_id'])
      expect(item.pipeline_stage_id).to eq(entry_stage.id)
      expect(item.pipeline_stage_id).not_to eq(later_stage.id)
      expect(item.custom_fields.dig('purchase', 'purchase_id')).to eq('ORD-1001')
      expect(item.custom_fields['value']).to eq(297.0)
      expect(item.assigned_by_id).to be_nil
    end

    it 'does NOT leave a second card on the default pipeline (skip_default_pipeline_assignment)' do
      default_pipeline = Pipeline.create!(name: "Default #{SecureRandom.hex(4)}", pipeline_type: 'sales',
                                          created_by: user, is_default: true)
      default_pipeline.pipeline_stages.create!(name: 'Novo', position: 1)

      post url, params: raw_body, headers: auth_headers

      contact = Contact.find(response.parsed_body['data']['contact_id'])
      expect(contact.pipeline_items.count).to eq(1)
      expect(contact.pipeline_items.sole.pipeline_id).to eq(pipeline.id)
    end

    it 'reuses an existing contact by e-mail additively (never clobbers CRM data)' do
      existing = Contact.create!(name: 'Maria CRM', email: 'maria@cliente.com', phone_number: '+5511977776666')

      expect do
        post url, params: raw_body, headers: auth_headers
      end.not_to change(Contact, :count)

      expect(response.parsed_body['data']['contact_id']).to eq(existing.id)
      expect(existing.reload.name).to eq('Maria CRM')
      expect(existing.phone_number).to eq('+5511977776666')
    end

    it 'captures a phone-only payload' do
      body = payload_hash.deep_dup
      body[:data][:customer].delete(:email)
      body = body.to_json

      post url, params: body, headers: auth_headers(body)

      expect(response).to have_http_status(:created)
      contact = Contact.find(response.parsed_body['data']['contact_id'])
      expect(contact.phone_number).to eq('+5511999998888')
    end

    it 'drops a phone too short to be a real number instead of minting a fake E.164' do
      body = { event: 'approved',
               data: { order_id: 'ORD-SHORT', customer: { name: 'Z', email: 'z@x.com', phone: '123' } } }.to_json

      post url, params: body, headers: auth_headers(body)

      expect(response).to have_http_status(:created)
      expect(Contact.find(response.parsed_body['data']['contact_id']).phone_number).to be_blank
    end

    it 'takes the row the concurrent winner inserted instead of 500ing on RecordNotUnique' do
      winner = Contact.create!(name: 'Winner', email: 'maria@cliente.com')
      doomed = Contact.new(email: 'maria@cliente.com')
      allow(doomed).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique.new('duplicate key'))
      allow(Contact).to receive(:new).and_return(doomed)
      allow(Contact).to receive(:from_email).and_return(nil, winner)

      post url, params: raw_body, headers: auth_headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['data']['contact_id']).to eq(winner.id)
    end
  end

  context 'when the outcome is a non-created ack or a distinct failure (AC2)' do
    it 'acks a non-approved event as ignored even with a MINIMAL payload (no contact fields)' do
      body = { event: 'refunded', data: { order_id: 'ORD-REFUND-1' } }.to_json

      expect do
        post url, params: body, headers: auth_headers(body)
      end.not_to change(PipelineItem, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data']['status']).to eq('ignored')
    end

    it 'still demands contact fields for an APPROVED event' do
      body = { event: 'approved', data: { order_id: 'ORD-NOCONTACT' } }.to_json

      post url, params: body, headers: auth_headers(body)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']['code']).to eq('MAPPING_ERROR')
    end

    it 'returns 422 MAPPING_ERROR when the payload has no purchase id' do
      body = { event: 'approved', data: { customer: { email: 'x@y.com' } } }.to_json

      post url, params: body, headers: auth_headers(body)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']['code']).to eq('MAPPING_ERROR')
    end

    it 'returns 422 when the destination pipeline does not resolve' do
      post registered_url(pipeline_id: SecureRandom.uuid), params: raw_body, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']['message']).to match(/pipeline/i)
    end

    ['[]', '[{"event":"approved"}]', '123', 'null'].each do |body|
      it "returns 422 (not a 500) for a signed JSON body that is not an object: #{body}" do
        post url, params: body, headers: auth_headers(body)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']['code']).to eq('MAPPING_ERROR')
      end
    end

    it 'refuses up front when the enterprise overlay left the request unbound' do
      stub_const('Evo::Enterprise::Licensing', Module.new { def self.current_tenant_id = nil })

      expect do
        post url, params: raw_body, headers: auth_headers
      end.not_to change(Contact, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']['message']).to match(/account/i)
    end
  end

  context 'when the same purchase is redelivered (AC4)' do
    it 'answers a redelivery with 200 duplicate and the ORIGINAL ids' do
      post url, params: raw_body, headers: auth_headers
      first = response.parsed_body['data']

      expect do
        post url, params: raw_body, headers: auth_headers
      end.to not_change(Contact, :count).and not_change(PipelineItem, :count)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body['data']
      expect(data['status']).to eq('duplicate')
      expect(data['pipeline_item_id']).to eq(first['pipeline_item_id'])
    end

    it 'acks a DIFFERENT purchase for a contact with an active card as already_in_pipeline' do
      post url, params: raw_body, headers: auth_headers
      first_item = response.parsed_body['data']['pipeline_item_id']

      body = payload_hash.deep_merge(data: { order_id: 'ORD-1002' }).to_json
      expect do
        post url, params: body, headers: auth_headers(body)
      end.not_to change(PipelineItem, :count)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body['data']
      expect(data['status']).to eq('already_in_pipeline')
      expect(data['pipeline_item_id']).to eq(first_item)
    end

    it 'keeps that second sale on the open card instead of dropping it, once' do
      post url, params: raw_body, headers: auth_headers
      item = PipelineItem.find(response.parsed_body['data']['pipeline_item_id'])

      body = payload_hash.deep_merge(data: { order_id: 'ORD-1002' }).to_json
      2.times { post url, params: body, headers: auth_headers(body) }

      history = item.reload.custom_fields['purchases']
      expect(history.map { |entry| entry['purchase_id'] }).to eq(['ORD-1002'])
    end

    it 'scopes the purchase identity by pipeline (same id on another pipeline is NOT a duplicate)' do
      post url, params: raw_body, headers: auth_headers

      other = Pipeline.create!(name: "Outro #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user)
      other.pipeline_stages.create!(name: 'Entrada', position: 1)
      body = payload_hash.deep_merge(data: { customer: { email: 'outra@cliente.com', phone: '11955554444' } }).to_json

      expect do
        post registered_url(pipeline_id: other.id), params: body, headers: auth_headers(body)
      end.to change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'allows a new card after the previous journey completed (second legit purchase)' do
      post url, params: raw_body, headers: auth_headers
      PipelineItem.find(response.parsed_body['data']['pipeline_item_id']).update!(completed_at: Time.current)

      body = payload_hash.deep_merge(data: { order_id: 'ORD-1002' }).to_json
      expect do
        post url, params: body, headers: auth_headers(body)
      end.to change(PipelineItem, :count).by(1)

      expect(response).to have_http_status(:created)
    end
  end
end
