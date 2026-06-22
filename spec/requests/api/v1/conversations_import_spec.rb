# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::ConversationsController#import', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Import Test', email: "import-#{SecureRandom.hex(4)}@example.com") }
  let(:permission_check_url) { "#{base_url}/api/v1/users/#{user.id}/check_permission" }

  let(:csv_header) do
    'conversation_external_id,contact_identifier,message_content,direction,sent_at,sender_name,message_type,message_external_id'
  end

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

  def csv_file(content, name: 'conv.csv')
    Rack::Test::UploadedFile.new(StringIO.new(content), 'text/csv', original_filename: name)
  end

  context 'when authenticated and authorized' do
    before do
      stub_auth_ok
      stub_permission(granted: true)
      Current.user = user
    end

    it 'AC2 — returns 202 with data_import_id on happy path' do
      csv = [csv_header, 'conv-1,id-1,Hi,incoming,2026-01-15T10:30:00Z,,text,m1'].join("\n")

      expect do
        post '/api/v1/conversations/import', params: { import_file: csv_file(csv) }, headers: headers
      end.to change(DataImport, :count).by(1)

      expect(response).to have_http_status(:accepted)
      body = response.parsed_body
      expect(body['data']['data_import_id']).to be_present
      expect(DataImport.find(body['data']['data_import_id']).data_type).to eq('conversations')
    end

    it 'returns 422 when import_file is missing' do
      post '/api/v1/conversations/import', params: {}, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'message')).to match(/File is required/i)
    end

    it 'AC9 — returns 422 when CSV exceeds 50k rows' do
      stub_const('Api::V1::ConversationsController::CONVERSATIONS_IMPORT_ROW_LIMIT', 2)
      csv = [
        csv_header,
        'conv-1,id-1,Hi,incoming,2026-01-15T10:30:00Z,,text,m1',
        'conv-1,id-1,Hi,incoming,2026-01-15T10:31:00Z,,text,m2',
        'conv-1,id-1,Hi,incoming,2026-01-15T10:32:00Z,,text,m3'
      ].join("\n")

      expect do
        post '/api/v1/conversations/import', params: { import_file: csv_file(csv) }, headers: headers
      end.not_to change(DataImport, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'message')).to match(/exceeds the maximum allowed rows/)
    end

    it 'returns 422 on malformed CSV' do
      malformed = "broken\"unterminated,quote\n\nfoo,bar\n"
      post '/api/v1/conversations/import', params: { import_file: csv_file(malformed) }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'message')).to match(/malformed/i)
    end

    it 'M3 — returns 422 when file exceeds byte size limit' do
      stub_const('Api::V1::ConversationsController::CONVERSATIONS_IMPORT_MAX_BYTES', 32)
      csv = [csv_header, 'conv-1,id-1,Hi,incoming,2026-01-15T10:30:00Z,,text,m1'].join("\n")

      expect do
        post '/api/v1/conversations/import', params: { import_file: csv_file(csv) }, headers: headers
      end.not_to change(DataImport, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'message')).to match(/maximum allowed size/i)
    end
  end

  context 'when permission is denied' do
    before do
      stub_auth_ok
      stub_permission(granted: false)
      Current.user = user
    end

    it 'returns 403' do
      csv = [csv_header, 'conv-1,id-1,Hi,incoming,2026-01-15T10:30:00Z,,text,m1'].join("\n")
      post '/api/v1/conversations/import', params: { import_file: csv_file(csv) }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(DataImport.count).to eq(0)
    end
  end
end
