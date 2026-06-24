# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::CannedResponses attachments', type: :request do
  let(:canned) { CannedResponse.create!(short_code: "cr-#{SecureRandom.hex(3)}", content: 'Hello there') }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  def attach_file!(record, title: 'doc.pdf')
    attachment = record.attachments.create!(file_type: :file, fallback_title: title)
    attachment.file.attach(io: StringIO.new('hello world'), filename: title, content_type: 'application/pdf')
    attachment
  end

  describe 'GET /api/v1/canned_responses/:id' do
    it 'returns an empty attachments array when there are none' do
      get "/api/v1/canned_responses/#{canned.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'attachments')).to eq([])
    end

    it 'returns serialized attachments when present' do
      attachment = attach_file!(canned)

      get "/api/v1/canned_responses/#{canned.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      data = json_response.dig('data', 'attachments')
      expect(data.size).to eq(1)
      expect(data.first['id']).to eq(attachment.id)
      expect(data.first['file_type']).to eq('file')
      expect(data.first['fallback_title']).to eq('doc.pdf')
      expect(data.first['data_url']).to be_present
    end
  end

  describe 'PATCH /api/v1/canned_responses/:id with remove_attachment_ids' do
    it 'detaches the specified attachment' do
      attachment = attach_file!(canned)

      patch "/api/v1/canned_responses/#{canned.id}",
            params: { canned_response: { content: 'Updated' }, remove_attachment_ids: [attachment.id] },
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(canned.reload.attachments.count).to eq(0)
      expect(json_response.dig('data', 'attachments')).to eq([])
    end

    it 'never removes attachments belonging to a different canned response' do
      other = CannedResponse.create!(short_code: "cr-#{SecureRandom.hex(3)}", content: 'Other')
      other_attachment = attach_file!(other)
      mine = attach_file!(canned)

      patch "/api/v1/canned_responses/#{canned.id}",
            params: { canned_response: { content: 'Updated' }, remove_attachment_ids: [other_attachment.id, mine.id] },
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(canned.reload.attachments.count).to eq(0)
      expect(other.reload.attachments.count).to eq(1)
    end
  end

  describe 'attachment size limit' do
    it 'rejects an attachment larger than the maximum size' do
      big = Tempfile.new(['big', '.pdf'])
      big.truncate(10.megabytes + 1)
      upload = Rack::Test::UploadedFile.new(big.path, 'application/pdf')

      patch "/api/v1/canned_responses/#{canned.id}",
            params: { canned_response: { content: 'Updated' }, attachments: [upload] },
            headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(canned.reload.attachments.count).to eq(0)
    ensure
      big&.close!
    end
  end

  describe 'invalid signed_id' do
    it 'rejects an attachment whose signed_id is invalid/expired with 422' do
      patch "/api/v1/canned_responses/#{canned.id}",
            params: { canned_response: { content: 'Updated' }, attachments: [{ signed_id: 'not-a-real-signed-id' }] },
            headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(canned.reload.attachments.count).to eq(0)
    end
  end
end
