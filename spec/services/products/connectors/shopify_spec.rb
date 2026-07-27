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

  it 'maps product image URLs (EVO-2226), capped at 5' do
    imgs = Array.new(7) { |i| { 'src' => "https://cdn.shopify.com/#{i}.jpg" } }
    stub_products({ 'products' => [
                    { 'title' => 'P', 'status' => 'active', 'variants' => [{ 'sku' => 'P1', 'price' => '1' }],
                      'images' => imgs }
                  ] })
    items = described_class.new(credentials).fetch_items
    expect(items.first[:image_urls].size).to eq(5)
    expect(items.first[:image_urls].first).to eq('https://cdn.shopify.com/0.jpg')
  end

  it 'omits image_urls when the product has no images' do
    stub_products({ 'products' => [{ 'title' => 'P', 'status' => 'active', 'variants' => [{ 'sku' => 'P1', 'price' => '1' }] }] })
    expect(described_class.new(credentials).fetch_items.first).not_to have_key(:image_urls)
  end

  it 'maps a variant that needs no shipping to a digital product' do
    stub_products({ 'products' => [
                    { 'title' => 'Ebook', 'status' => 'active',
                      'variants' => [{ 'sku' => 'EB', 'price' => '5.00', 'requires_shipping' => false }] },
                    { 'title' => 'Mug', 'status' => 'active',
                      'variants' => [{ 'sku' => 'MG', 'price' => '9.90', 'requires_shipping' => true }] }
                  ] })

    items = described_class.new(credentials).fetch_items

    expect(items.first).to include(name: 'Ebook', kind: 'digital')
    expect(items.second).to include(name: 'Mug', kind: 'physical')
  end

  # /products/bulk creates one row per product, so extra variants cannot be carried —
  # they must be counted, not silently dropped.
  it 'counts the variants past the first instead of dropping them silently' do
    stub_products({ 'products' => [
                    { 'title' => 'Tee', 'status' => 'active',
                      'variants' => [{ 'sku' => 'T-P', 'price' => '9.90' }, { 'sku' => 'T-M' }, { 'sku' => 'T-G' }] },
                    { 'title' => 'Mug', 'status' => 'active', 'variants' => [{ 'sku' => 'MG', 'price' => '1' }] }
                  ] })

    connector = described_class.new(credentials)
    items = connector.fetch_items

    expect(items.size).to eq(2)
    expect(items.first).to include(sku: 'T-P') # first variant is the one that survives
    expect(connector.variants_dropped).to eq(2)
  end

  # A 200 that is not JSON parses to a String, and String#[]('title') would mine the
  # HTML for a plausible-looking product instead of failing.
  it 'raises ConnectorError on a 200 whose body is not JSON' do
    stub_request(:get, url)
      .with(query: hash_including({}))
      .to_return(status: 200, body: '<html><title>Just a moment…</title></html>',
                 headers: { 'Content-Type' => 'text/html' })

    expect { described_class.new(credentials).fetch_items }
      .to raise_error(Products::Connectors::ConnectorError, /non-JSON response/)
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

  # EVO-2225: Shopify caps limit at 250, so a >250 catalog needs cursor pagination.
  it 'follows the Link rel=next cursor across pages and concatenates the catalog' do
    page1 = 'https://test.myshopify.com/admin/api/2024-01/products.json?limit=250'
    page2 = "#{page1}&page_info=NEXT"
    stub_request(:get, page1)
      .with(headers: { 'X-Shopify-Access-Token' => 'shpat_xxx' })
      .to_return(status: 200,
                 body: { 'products' => [{ 'title' => 'A', 'status' => 'active', 'variants' => [{ 'sku' => 'A' }] }] }.to_json,
                 headers: { 'Content-Type' => 'application/json', 'Link' => "<#{page2}>; rel=\"next\"" })
    stub_request(:get, page2)
      .with(headers: { 'X-Shopify-Access-Token' => 'shpat_xxx' })
      .to_return(status: 200,
                 body: { 'products' => [{ 'title' => 'B', 'status' => 'active', 'variants' => [{ 'sku' => 'B' }] }] }.to_json,
                 headers: { 'Content-Type' => 'application/json' }) # no Link → last page

    # Without pagination this returns only %w[A] — the negative proof for EVO-2225.
    expect(described_class.new(credentials).fetch_items.map { |i| i[:name] }).to eq(%w[A B])
  end

  it 'stops at the request ceiling when the store keeps advertising a next page (no infinite loop)' do
    loop_url = 'https://test.myshopify.com/admin/api/2024-01/products.json?limit=250&page_info=LOOP'
    stub_request(:get, %r{test\.myshopify\.com/admin/api/2024-01/products\.json})
      .to_return(status: 200,
                 body: { 'products' => [{ 'title' => 'X', 'status' => 'active', 'variants' => [{ 'sku' => 'X' }] }] }.to_json,
                 headers: { 'Content-Type' => 'application/json', 'Link' => "<#{loop_url}>; rel=\"next\"" })

    connector = described_class.new(credentials)
    items = connector.fetch_items

    expect(items.size).to eq(described_class::MAX_PAGE_REQUESTS)
    expect(connector).to be_truncated # stopped on a budget → the caller warns the user
    expect(a_request(:get, %r{test\.myshopify\.com/admin/api/2024-01/products\.json}))
      .to have_been_made.times(described_class::MAX_PAGE_REQUESTS)
  end

  # The Link header comes from the store, so following it blindly would hand the Admin
  # API token (sent on every page request) to a host the response picked.
  it 'refuses a Link next-URL pointing at another host' do
    stub_request(:get, 'https://test.myshopify.com/admin/api/2024-01/products.json?limit=250')
      .to_return(status: 200,
                 body: { 'products' => [{ 'title' => 'A', 'status' => 'active', 'variants' => [{ 'sku' => 'A' }] }] }.to_json,
                 headers: { 'Content-Type' => 'application/json',
                            'Link' => '<https://attacker.example/products.json?page_info=X>; rel="next"' })

    expect { described_class.new(credentials).fetch_items }
      .to raise_error(Products::Connectors::ConnectorError, /another host/)
  end

  it 'runs the SSRF guard on every page, so a next-URL that resolves internally is refused' do
    page2 = 'https://test.myshopify.com/admin/api/2024-01/products.json?limit=250&page_info=NEXT'
    stub_request(:get, 'https://test.myshopify.com/admin/api/2024-01/products.json?limit=250')
      .to_return(status: 200,
                 body: { 'products' => [{ 'title' => 'A', 'status' => 'active', 'variants' => [{ 'sku' => 'A' }] }] }.to_json,
                 headers: { 'Content-Type' => 'application/json', 'Link' => "<#{page2}>; rel=\"next\"" })
    # Page 1 resolves public, the cursor page then resolves internally (DNS rebinding
    # across pages) — the guard has to run per request, not once at the start.
    allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34'], ['169.254.169.254'])

    expect { described_class.new(credentials).fetch_items }
      .to raise_error(Products::Connectors::ConnectorError, /private/)
  end
end
