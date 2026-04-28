# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::TeamMembers', type: :request do
  let(:team) { Team.create!(name: "Spec Team #{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "user-#{SecureRandom.hex(4)}@example.com", name: 'Member User') }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  around do |example|
    original = ENV.fetch('EVOAI_CRM_API_TOKEN', nil)
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    begin
      example.run
    ensure
      if original.nil?
        ENV.delete('EVOAI_CRM_API_TOKEN')
      else
        ENV['EVOAI_CRM_API_TOKEN'] = original
      end
      Current.reset
    end
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'POST /api/v1/teams/:team_id/team_members' do
    it 'adds a valid user UUID to the team and returns 200' do
      post "/api/v1/teams/#{team.id}/team_members",
           params: { user_ids: [user.id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(team.reload.members.pluck(:id)).to include(user.id)
      expect(json_response['success']).to be(true)
    end

    it 'returns 422 with VALIDATION_ERROR (not 401) when a user_id does not reference an existing user' do
      missing_uuid = SecureRandom.uuid

      post "/api/v1/teams/#{team.id}/team_members",
           params: { user_ids: [missing_uuid] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response).not_to have_http_status(:unauthorized)
      expect(json_response.dig('error', 'code')).to eq('VALIDATION_ERROR')
      expect(team.reload.members).to be_empty
    end

    it 'is idempotent for users already in the team' do
      team.add_members([user.id])

      post "/api/v1/teams/#{team.id}/team_members",
           params: { user_ids: [user.id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(team.reload.members.pluck(:id)).to eq([user.id])
    end

    it 'returns 422 (not 500) when user_ids is missing entirely' do
      post "/api/v1/teams/#{team.id}/team_members",
           params: {},
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response.dig('error', 'code')).to eq('VALIDATION_ERROR')
    end

    it 'returns 422 when user_ids is a single string instead of an array' do
      post "/api/v1/teams/#{team.id}/team_members",
           params: { user_ids: user.id },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response.dig('error', 'code')).to eq('VALIDATION_ERROR')
    end
  end

  describe 'PATCH /api/v1/teams/:team_id/team_members' do
    it 'returns 422 with VALIDATION_ERROR (not 401) when a user_id does not reference an existing user' do
      missing_uuid = SecureRandom.uuid

      patch "/api/v1/teams/#{team.id}/team_members",
            params: { user_ids: [missing_uuid] },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response).not_to have_http_status(:unauthorized)
      expect(json_response.dig('error', 'code')).to eq('VALIDATION_ERROR')
      expect(team.reload.members).to be_empty
    end

    it 'returns 422 when user_ids is missing entirely' do
      patch "/api/v1/teams/#{team.id}/team_members",
            params: {},
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response.dig('error', 'code')).to eq('VALIDATION_ERROR')
    end
  end

  describe 'DELETE /api/v1/teams/:team_id/team_members' do
    it 'removes a valid user UUID from the team and returns 200' do
      team.add_members([user.id])

      delete "/api/v1/teams/#{team.id}/team_members",
             params: { user_ids: [user.id] },
             headers: headers,
             as: :json

      expect(response).to have_http_status(:ok)
      expect(team.reload.members).to be_empty
    end

    it 'returns 422 when user_ids is missing entirely' do
      delete "/api/v1/teams/#{team.id}/team_members",
             params: {},
             headers: headers,
             as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response.dig('error', 'code')).to eq('VALIDATION_ERROR')
    end
  end
end
