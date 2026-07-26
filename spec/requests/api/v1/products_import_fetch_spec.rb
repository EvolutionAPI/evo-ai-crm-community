# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-1785 (Phase 2): POST /api/v1/products/import_fetch fetches a store's products
# from a remote source and returns them mapped into the bulk-import item shape (the
# client then runs them through the existing /products/bulk dry-run + import). Gated by
# `products.create`. We WebMock evo-auth (so the gate + Current.user resolve) and the
# source's API (so no real store is needed).
RSpec.describe 'Api::V1::Products import_fetch (EVO-1785)', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Importer', email: "imp-#{SecureRandom.hex(4)}@example.com") }
  let(:shop_url) { 'https://test.myshopify.com/admin/api/2024-01/products.json' }
  let(:credentials) { { shop_domain: 'test.myshopify.com', access_token: 'shpat_xxx' } }

  around do |example|
    original = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original
  end

  # SSRF guard is hermetic: test hosts resolve to a fixed public IP (the SSRF test
  # overrides with a private one).
  before { allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34']) }

  def json_response
    response.parsed_body
  end

  def stub_auth(granted:)
    stub_request(:post, "#{base_url}/api/v1/auth/validate")
      .to_return(status: 200,
                 body: { success: true,
                         data: { user: { id: user.id, email: user.email, role: { id: 1, key: 'r', name: 'r' } } } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |req|
        key = JSON.parse(req.body)['permission_key']
        { status: 200, body: { success: true, data: { has_permission: granted.include?(key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' } }
      end
  end

  def stub_shopify(body, status: 200)
    stub_request(:get, shop_url)
      .with(query: hash_including({}))
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def post_fetch(source, creds)
    post '/api/v1/products/import_fetch', params: { source: source, credentials: creds }, headers: headers, as: :json
  end

  context 'with products.create' do
    before { stub_auth(granted: %w[products.create]) }

    it 'fetches and maps a source\'s products into bulk-import items' do
      stub_shopify({ 'products' => [
                     { 'title' => 'Widget', 'status' => 'active',
                       'variants' => [{ 'sku' => 'W-1', 'price' => '19.90' }] }
                   ] })

      post_fetch('shopify', credentials)

      expect(response).to have_http_status(:ok)
      items = json_response['data']['items']
      expect(items.size).to eq(1)
      expect(items.first).to include('name' => 'Widget', 'sku' => 'W-1', 'default_price' => '19.90')
      expect(json_response['meta']).to include('source' => 'shopify', 'count' => 1)
    end

    it 'surfaces the connector error as a 422 when the store rejects the credentials' do
      stub_shopify({ errors: 'unauthorized' }, status: 401)

      post_fetch('shopify', credentials)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('401')
    end

    it 'returns 422 for an unsupported source' do
      post_fetch('magento', credentials)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('unsupported import source')
    end

    it 'returns 422 when the source has no products' do
      stub_shopify({ 'products' => [] })
      post_fetch('shopify', credentials)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('No products found')
    end

    it 'returns 422 (not 500) when credentials are omitted entirely' do
      post '/api/v1/products/import_fetch', params: { source: 'shopify' }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('missing credential')
    end

    it 'refuses a source whose host resolves to a private address (SSRF, 422)' do
      allow(Resolv).to receive(:getaddresses).and_return(['127.0.0.1'])
      post_fetch('shopify', credentials)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('private')
    end
  end

  context 'without products.create' do
    before { stub_auth(granted: %w[products.read]) }

    it 'forbids the fetch' do
      post_fetch('shopify', credentials)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
