# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Products::ImageAttacher do
  let(:product) { Product.create!(name: 'Manual upload', kind: 'physical') }
  let(:fixture) { Rails.root.join('spec/fixtures/files/product_image.png') }

  def upload(content_type: 'image/png', filename: 'photo.png')
    Rack::Test::UploadedFile.new(fixture, content_type, original_filename: filename)
  end

  it 'attaches a valid multipart upload and rejects nothing' do
    rejected = described_class.new(product).call([upload])

    expect(rejected).to be_empty
    expect(product.images).to be_attached
    expect(product.images.first.filename.to_s).to eq('photo.png')
  end

  it 'rejects a non-image content type without attaching' do
    rejected = described_class.new(product).call([upload(content_type: 'application/pdf', filename: 'doc.pdf')])

    expect(product.images).not_to be_attached
    expect(rejected.map(&:reason)).to eq(['invalid_type'])
    expect(rejected.first.filename).to eq('doc.pdf')
  end

  it 'rejects an upload over the size cap without attaching' do
    oversized = upload
    allow(oversized).to receive(:size).and_return(Products::ImagePolicy::MAX_BYTES + 1)

    rejected = described_class.new(product).call([oversized])

    expect(product.images).not_to be_attached
    expect(rejected.map(&:reason)).to eq(['too_large'])
  end

  it 'rejects an empty upload' do
    empty = upload
    allow(empty).to receive(:size).and_return(0)

    expect(described_class.new(product).call([empty]).map(&:reason)).to eq(['empty'])
  end

  # EVO-2226: the manual path had no quantity cap — a product could take unbounded
  # 5 MB attachments, and they accumulate across edits.
  it 'stops at MAX_PER_PRODUCT and reports the surplus' do
    cap = Products::ImagePolicy::MAX_PER_PRODUCT
    rejected = described_class.new(product).call(Array.new(cap + 2) { upload })

    expect(product.images.count).to eq(cap)
    expect(rejected.map(&:reason)).to eq(%w[too_many too_many])
  end

  it 'counts images already attached in earlier requests against the cap' do
    cap = Products::ImagePolicy::MAX_PER_PRODUCT
    described_class.new(product).call(Array.new(cap) { upload })

    rejected = described_class.new(product.reload).call([upload])

    expect(product.images.count).to eq(cap)
    expect(rejected.map(&:reason)).to eq(['too_many'])
  end

  it 'attaches a valid ActiveStorage signed_id (direct upload path)' do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(fixture), filename: 'signed.png', content_type: 'image/png'
    )

    rejected = described_class.new(product).call([blob.signed_id])

    expect(rejected).to be_empty
    expect(product.images.count).to eq(1)
  end

  it 'reports a tampered signed_id instead of raising' do
    rejected = described_class.new(product).call(['not-a-valid-signed-id'])

    expect(product.images).not_to be_attached
    expect(rejected.map(&:reason)).to eq(['invalid_signature'])
  end

  it 'is a no-op for blank input' do
    expect(described_class.new(product).call(nil)).to be_empty
    expect(product.images).not_to be_attached
  end
end
