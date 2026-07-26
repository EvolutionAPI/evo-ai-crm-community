# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Products::Connectors::WooCommerce do
  let(:credentials) { { store_url: 'https://shop.example.com', consumer_key: 'ck_1', consumer_secret: 'cs_1' } }
  let(:url) { 'https://shop.example.com/wp-json/wc/v3/products' }

  # Keep the SSRF guard hermetic: resolve test hosts to a fixed public IP.
  before { allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34']) }

  def stub_products(body, status: 200)
    stub_request(:get, url)
      .with(query: hash_including({}), basic_auth: %w[ck_1 cs_1])
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'maps WooCommerce products into bulk-import items (virtual→digital, price fallback, html stripped)' do
    stub_products([
                    { 'name' => 'Mug', 'short_description' => '<p>Ceramic</p>', 'sku' => 'MUG', 'price' => '9.90',
                      'status' => 'publish', 'virtual' => false, 'stock_quantity' => 12,
                      'permalink' => 'https://shop.example.com/mug' },
                    { 'name' => 'Ebook', 'short_description' => '', 'description' => 'A digital book', 'sku' => 'EB',
                      'price' => '', 'regular_price' => '5.00', 'status' => 'draft', 'virtual' => true,
                      'stock_quantity' => nil, 'permalink' => 'https://shop.example.com/eb' }
                  ])

    items = described_class.new(credentials).fetch_items

    expect(items.first).to include(name: 'Mug', sku: 'MUG', default_price: '9.90', status: 'active',
                                   kind: 'physical', stock_quantity: 12,
                                   purchase_url: 'https://shop.example.com/mug')
    expect(items.first[:description]).to eq('Ceramic')
    expect(items.second).to include(name: 'Ebook', default_price: '5.00', status: 'draft', kind: 'digital',
                                    description: 'A digital book') # short_description blank → falls back
  end

  it 'raises ConnectorError on a non-2xx (bad key pair)' do
    stub_products({ message: 'bad key' }, status: 401)
    expect { described_class.new(credentials).fetch_items }
      .to raise_error(Products::Connectors::ConnectorError, /401/)
  end

  it 'prefixes https:// when store_url has no scheme' do
    stub_request(:get, 'https://bare.example.com/wp-json/wc/v3/products')
      .with(query: hash_including({}), basic_auth: %w[ck_1 cs_1])
      .to_return(status: 200, body: '[]', headers: { 'Content-Type' => 'application/json' })

    expect do
      described_class.new(store_url: 'bare.example.com', consumer_key: 'ck_1', consumer_secret: 'cs_1').fetch_items
    end.not_to raise_error
  end

  it 'refuses a store_url that resolves to a private/internal address (SSRF guard)' do
    allow(Resolv).to receive(:getaddresses).and_return(['10.0.0.5'])
    expect { described_class.new(credentials).fetch_items }
      .to raise_error(Products::Connectors::ConnectorError, /private/)
  end

  # EVO-2225: WooCommerce caps per_page at 100, so a >100 catalog needs ?page=N walking.
  it 'pages through ?page=N up to X-WP-TotalPages and concatenates the catalog' do
    stub_request(:get, url)
      .with(query: hash_including('page' => '1'), basic_auth: %w[ck_1 cs_1])
      .to_return(status: 200, body: [{ 'name' => 'A', 'status' => 'publish' }].to_json,
                 headers: { 'Content-Type' => 'application/json', 'X-WP-TotalPages' => '2' })
    stub_request(:get, url)
      .with(query: hash_including('page' => '2'), basic_auth: %w[ck_1 cs_1])
      .to_return(status: 200, body: [{ 'name' => 'B', 'status' => 'publish' }].to_json,
                 headers: { 'Content-Type' => 'application/json', 'X-WP-TotalPages' => '2' })

    # Without pagination this returns only %w[A] — the negative proof for EVO-2225.
    expect(described_class.new(credentials).fetch_items.map { |i| i[:name] }).to eq(%w[A B])
  end

  it 'stops at the page cap even when the store advertises far more pages (no runaway)' do
    stub_request(:get, url)
      .with(query: hash_including({}), basic_auth: %w[ck_1 cs_1])
      .to_return(status: 200, body: [{ 'name' => 'P', 'status' => 'publish' }].to_json,
                 headers: { 'Content-Type' => 'application/json', 'X-WP-TotalPages' => '999' })

    items = described_class.new(credentials).fetch_items
    expect(items.size).to eq(5) # max_pages = ceil(500 / 100) = 5
    expect(a_request(:get, url).with(query: hash_including({}))).to have_been_made.times(5)
  end
end
