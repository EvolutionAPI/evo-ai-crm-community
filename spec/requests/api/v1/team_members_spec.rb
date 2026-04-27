# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/teams/:team_id/team_members', type: :request do
  let(:team) { Team.create!(name: "Spec Team #{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "user-#{SecureRandom.hex(4)}@example.com", name: 'Member User') }
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

    # The controller subtracts current_members_ids from params[:user_ids] before
    # add_members runs, so re-posting an existing member is a no-op (200), not
    # a 401 or 422.
    post "/api/v1/teams/#{team.id}/team_members",
         params: { user_ids: [user.id] },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(team.reload.members.pluck(:id)).to eq([user.id])
  end
end
