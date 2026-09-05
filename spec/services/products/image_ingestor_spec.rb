# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Products::ImageIngestor do
  let(:product) { Product.create!(name: 'Imported', kind: 'physical') }
  # A 1x1 PNG.
  let(:png_bytes) do
    Base64.decode64(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
    )
  end

  # Keep the SSRF guard hermetic: resolve test hosts to a fixed public IP.
  before { allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34']) }

  def stub_image(url, body:, content_type: 'image/png', status: 200)
    stub_request(:get, url).to_return(status: status, body: body, headers: { 'Content-Type' => content_type })
  end

  it 'downloads and attaches a valid image' do
    stub_image('https://cdn.example.com/a.png', body: png_bytes)
    described_class.attach_all(product, ['https://cdn.example.com/a.png'])
    expect(product.images).to be_attached
    expect(product.images.first.content_type).to eq('image/png')
  end

  it 'downloads at most MAX_PER_IMPORT URLs per product' do
    urls = Array.new(Products::ImagePolicy::MAX_PER_IMPORT + 2) { |i| "https://cdn.example.com/#{i}.png" }
    urls.each { |u| stub_image(u, body: png_bytes) }
    described_class.attach_all(product, urls)
    expect(product.images.count).to eq(Products::ImagePolicy::MAX_PER_IMPORT)
  end

  # The per-product ceiling is shared with the manual upload path.
  it 'respects the slots already used on the product' do
    allow(Products::ImagePolicy).to receive(:remaining_slots).and_return(1)
    urls = Array.new(3) { |i| "https://cdn.example.com/#{i}.png" }
    urls.each { |u| stub_image(u, body: png_bytes) }

    described_class.attach_all(product, urls)

    expect(product.images.count).to eq(1)
  end

  it 'skips a non-image content type' do
    stub_image('https://cdn.example.com/x.html', body: '<html></html>', content_type: 'text/html')
    described_class.attach_all(product, ['https://cdn.example.com/x.html'])
    expect(product.images).not_to be_attached
  end

  it 'skips an oversized image (> MAX_BYTES)' do
    stub_image('https://cdn.example.com/big.png', body: 'x' * (Products::ImagePolicy::MAX_BYTES + 1))
    described_class.attach_all(product, ['https://cdn.example.com/big.png'])
    expect(product.images).not_to be_attached
  end

  # The cap must bite before the body is buffered, so a hostile URL cannot size our
  # allocation. A truthful Content-Length is refused without reading the body.
  it 'refuses on a Content-Length over the cap without downloading the body' do
    stub_request(:get, 'https://cdn.example.com/huge.png')
      .to_return(
        status: 200,
        body: png_bytes,
        headers: { 'Content-Type' => 'image/png', 'Content-Length' => (Products::ImagePolicy::MAX_BYTES + 1).to_s }
      )

    described_class.attach_all(product, ['https://cdn.example.com/huge.png'])

    expect(product.images).not_to be_attached
  end

  it 'skips an empty body' do
    stub_image('https://cdn.example.com/empty.png', body: '')
    described_class.attach_all(product, ['https://cdn.example.com/empty.png'])
    expect(product.images).not_to be_attached
  end

  it 'does not follow redirects to a host that never passed the guard' do
    stub_request(:get, 'https://cdn.example.com/moved.png')
      .to_return(status: 302, headers: { 'Location' => 'http://169.254.169.254/latest/meta-data' })

    described_class.attach_all(product, ['https://cdn.example.com/moved.png'])

    expect(product.images).not_to be_attached
  end

  it 'refuses a URL that resolves to a private/internal address (SSRF)' do
    allow(Resolv).to receive(:getaddresses).and_return(['169.254.169.254'])
    # No stub — a request would blow up WebMock; the guard must short-circuit first.
    described_class.attach_all(product, ['https://metadata.internal/a.png'])
    expect(product.images).not_to be_attached
  end

  it 'refuses a non-http(s) scheme' do
    described_class.attach_all(product, ['file:///etc/passwd'])
    expect(product.images).not_to be_attached
  end

  it 'is non-fatal when the download errors' do
    stub_request(:get, 'https://cdn.example.com/boom.png').to_raise(SocketError)
    expect { described_class.attach_all(product, ['https://cdn.example.com/boom.png']) }.not_to raise_error
    expect(product.images).not_to be_attached
  end
end
