# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Products::Connectors::Shopify do
  let(:credentials) { { shop_domain: 'test.myshopify.com', access_token: 'shpat_xxx' } }
  let(:url) { 'https://test.myshopify.com/admin/api/2024-01/products.json' }

  # Keep the SSRF guard hermetic: resolve test hosts to a fixed public IP instead of
  # hitting real DNS. The SSRF test overrides this with a private address.
  before { allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34']) }

  def stub_products(body, status: 200)
    stub_request(:get, url)
      .with(query: hash_including({}), headers: { 'X-Shopify-Access-Token' => 'shpat_xxx' })
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'maps Shopify products into bulk-import items (html stripped, blank sku dropped, status folded)' do
    stub_products({ 'products' => [
                    { 'title' => 'Widget', 'body_html' => '<p>Nice <b>widget</b></p>', 'status' => 'active',
                      'variants' => [{ 'sku' => 'W-1', 'price' => '19.90', 'inventory_quantity' => 5 }] },
                    { 'title' => 'Archived thing', 'body_html' => nil, 'status' => 'archived',
                      'variants' => [{ 'sku' => nil, 'price' => '0.00' }] }
                  ] })

    items = described_class.new(credentials).fetch_items

    expect(items.size).to eq(2)
    expect(items.first).to include(name: 'Widget', sku: 'W-1', default_price: '19.90',
                                   status: 'active', kind: 'physical', stock_quantity: 5)
    expect(items.first[:description]).to eq('Nice widget')
    expect(items.second).to include(name: 'Archived thing', status: 'draft') # archived → draft
    expect(items.second).not_to have_key(:sku) # blank sku compacted out
  end

  it 'raises ConnectorError on a non-2xx (bad token)' do
    stub_products({ errors: 'unauthorized' }, status: 401)
    expect { described_class.new(credentials).fetch_items }
      .to raise_error(Products::Connectors::ConnectorError, /401/)
  end

  it 'raises ConnectorError when a credential is missing' do
    expect { described_class.new(shop_domain: 'test.myshopify.com').fetch_items }
      .to raise_error(Products::Connectors::ConnectorError, /access_token/)
  end

  it 'accepts a full URL as shop_domain (normalized to the host)' do
    stub_products({ 'products' => [] })
    expect { described_class.new(shop_domain: 'https://test.myshopify.com/', access_token: 'shpat_xxx').fetch_items }
      .not_to raise_error
  end

  it 'refuses a host that resolves to a private/internal address (SSRF guard)' do
    allow(Resolv).to receive(:getaddresses).and_return(['169.254.169.254'])
    expect { described_class.new(credentials).fetch_items }
      .to raise_error(Products::Connectors::ConnectorError, /private/)
  end
end
