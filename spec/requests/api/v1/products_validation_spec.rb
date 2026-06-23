# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::ProductsController validation errors', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Products Validation User', email: "products-val-#{SecureRandom.hex(4)}@example.com") }
  let(:permission_check_url) { "#{base_url}/api/v1/users/#{user.id}/check_permission" }

  around do |example|
    original_base_url = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
  end

  def stub_auth_ok
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: { success: true, data: { user: { id: user.id, email: user.email } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_permission(granted:)
    stub_request(:post, permission_check_url)
      .to_return(
        status: 200,
        body: { success: true, data: { has_permission: granted } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def product_payload(sku)
    { name: 'Sample', kind: 'physical', default_price: 10, currency: 'BRL', sku: sku }
  end

  before do
    stub_auth_ok
    stub_permission(granted: true)
    Current.user = user
  end

  context 'when SKU is already taken (AC4 inline field error)' do
    let!(:existing) { Product.create!(product_payload('DUP-SKU')) }

    it 'returns a 422 with details keyed by field so the frontend can render it inline' do
      expect do
        post '/api/v1/products', params: { product: product_payload('DUP-SKU') }, headers: headers, as: :json
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)

      details = response.parsed_body.dig('error', 'details')
      expect(details).to be_an(Array)

      sku_error = details.find { |d| d['field'] == 'sku' }
      expect(sku_error).to be_present
      expect(sku_error['messages']).to include(match(/taken/i))
      expect(sku_error['full_messages']).to include(match(/sku/i))
    end
  end

  context 'when the create payload is otherwise invalid' do
    it 'returns a 422 (not a 500) for a blank name' do
      post '/api/v1/products',
           params: { product: { kind: 'physical', default_price: 10, currency: 'BRL' } },
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      fields = response.parsed_body.dig('error', 'details').map { |d| d['field'] }
      expect(fields).to include('name')
    end
  end

  context 'when the product does not exist' do
    it 'returns a 404 (not a 500) — the error_response call must be well-formed' do
      get '/api/v1/products/00000000-0000-0000-0000-000000000000', headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig('error', 'code')).to eq('RESOURCE_NOT_FOUND')
    end
  end
end
