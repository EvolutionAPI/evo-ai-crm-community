# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::MacrosController', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Test User', email: "macros-test-#{SecureRandom.hex(4)}@example.com") }

  around do |example|
    original_base_url = ENV['EVO_AUTH_SERVICE_URL']
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
        body: {
          success: true,
          data: {
            user: { id: user.id, email: user.email }
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    permission_check_url = "#{base_url}/api/v1/users/#{user.id}/check_permission"
    stub_request(:post, permission_check_url)
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { has_permission: true }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    Current.user = user
  end

  describe 'POST /api/v1/macros' do
    it 'creates a macro successfully' do
      post '/api/v1/macros',
           params: {
             name: 'Test Macro',
             actions: [{ action_name: 'assign_team', action_params: ['1'] }],
             visibility: 'global'
           },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      parsed = JSON.parse(response.body)
      expect(parsed['data']['name']).to eq('Test Macro')
    end

    # CRM-54: the form used to save `parseInt(uuid) || uuid`, truncating every
    # uuid that starts with a hex digit 1-9 before it reached this endpoint.
    # The whole range is covered so a reintroduced coercion is caught here.
    %w[0 1 2 3 4 5 6 7 8 9 a b c d e f].each do |first_digit|
      it "persists an action param uuid starting with #{first_digit} verbatim" do
        team_id = "#{first_digit}#{SecureRandom.uuid[1..]}"

        post '/api/v1/macros',
             params: {
               name: "Macro #{first_digit}",
               actions: [{ action_name: 'assign_team', action_params: [team_id] }],
               visibility: 'global'
             },
             headers: headers,
             as: :json

        expect(response).to have_http_status(:success)
        created = response.parsed_body['data']
        expect(created['actions'].first['action_params']).to eq([team_id])

        # Reopening the macro must show the very same selection back.
        get "/api/v1/macros/#{created['id']}", headers: headers, as: :json

        expect(response).to have_http_status(:success)
        reopened = response.parsed_body['data']
        expect(reopened['actions'].first['action_params']).to eq([team_id])
      end
    end
  end
end
