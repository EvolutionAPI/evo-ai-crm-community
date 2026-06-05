# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/v1/canned_responses/:id', type: :request do
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

  it 'returns the canned response by id' do
    get "/api/v1/canned_responses/#{canned.id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(json_response.dig('data', 'id')).to eq(canned.id)
    expect(json_response.dig('data', 'content')).to eq('Hello there')
  end
end
