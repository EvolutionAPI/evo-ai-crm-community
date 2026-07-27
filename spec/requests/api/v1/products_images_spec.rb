# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# The manual upload path end-to-end over real multipart (EVO-2226).
RSpec.describe 'Api::V1::ProductsController product images', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Image Test User', email: "products-images-#{SecureRandom.hex(4)}@example.com") }
  let(:permission_check_url) { "#{base_url}/api/v1/users/#{user.id}/check_permission" }
  let(:fixture) { Rails.root.join('spec/fixtures/files/product_image.png') }

  def image_upload(content_type: 'image/png', filename: 'photo.png')
    Rack::Test::UploadedFile.new(fixture, content_type, original_filename: filename)
  end

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

  before do
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: { success: true, data: { user: { id: user.id, email: user.email } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
    stub_request(:post, permission_check_url)
      .to_return(
        status: 200,
        body: { success: true, data: { has_permission: true } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
    Current.user = user
  end

  def created_product
    Product.find(response.parsed_body['data']['id'])
  end

  describe 'POST /api/v1/products with a raw multipart image' do
    it 'attaches the uploaded file' do
      post '/api/v1/products',
           params: { product: { name: 'With photo', kind: 'physical', images: [image_upload] } },
           headers: headers

      expect(response).to have_http_status(:created)
      expect(created_product.images).to be_attached
      expect(created_product.images.first.filename.to_s).to eq('photo.png')
    end

    # The client switches to multipart once a file is picked, and nested attributes have
    # to survive it — sent as a JSON string, strong params drops them silently.
    it 'still creates nested variants when the request is multipart' do
      post '/api/v1/products',
           params: {
             product: {
               name: 'Shirt', kind: 'physical',
               images: [image_upload],
               variants_attributes: [
                 { name: 'M', sku: "SH-M-#{SecureRandom.hex(3)}", position: 0 },
                 { name: 'G', sku: "SH-G-#{SecureRandom.hex(3)}", position: 1 }
               ]
             }
           },
           headers: headers

      expect(response).to have_http_status(:created)
      product = created_product
      expect(product.images).to be_attached
      expect(product.variants.pluck(:name)).to contain_exactly('M', 'G')
    end

    it 'applies labels sent alongside a multipart image' do
      post '/api/v1/products',
           params: { product: { name: 'Labelled', kind: 'physical', images: [image_upload], labels: %w[promo novo] } },
           headers: headers

      expect(response).to have_http_status(:created)
      expect(created_product.label_list).to contain_exactly('promo', 'novo')
    end

    it 'reports a refused file in meta instead of dropping it silently' do
      post '/api/v1/products',
           params: {
             product: {
               name: 'Bad upload', kind: 'physical',
               images: [image_upload(content_type: 'application/pdf', filename: 'doc.pdf')]
             }
           },
           headers: headers

      expect(response).to have_http_status(:created)
      expect(created_product.images).not_to be_attached

      rejected = response.parsed_body.dig('meta', 'images_rejected')
      expect(rejected).to eq([{ 'filename' => 'doc.pdf', 'reason' => 'invalid_type' }])
    end

    it 'omits images_rejected when everything was accepted' do
      post '/api/v1/products',
           params: { product: { name: 'Clean', kind: 'physical', images: [image_upload] } },
           headers: headers

      expect(response.parsed_body['meta']).not_to have_key('images_rejected')
    end
  end

  describe 'PATCH /api/v1/products/:id with a raw multipart image' do
    let(:product) { Product.create!(name: 'Editable', kind: 'physical') }

    it 'attaches on update and keeps the scalar edits' do
      patch "/api/v1/products/#{product.id}",
            params: { product: { name: 'Renamed', images: [image_upload] } },
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(product.reload.name).to eq('Renamed')
      expect(product.images).to be_attached
    end

    it 'refuses to grow past the per-product ceiling across requests' do
      cap = Products::ImagePolicy::MAX_PER_PRODUCT
      cap.times do
        patch "/api/v1/products/#{product.id}", params: { product: { images: [image_upload] } }, headers: headers
      end

      patch "/api/v1/products/#{product.id}", params: { product: { images: [image_upload] } }, headers: headers

      expect(product.reload.images.count).to eq(cap)
      expect(response.parsed_body.dig('meta', 'images_rejected').first['reason']).to eq('too_many')
    end
  end
end
