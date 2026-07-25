# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-2222 — `team` pipeline visibility, end-to-end through the gate. The by_* endpoints
# feed the pipeline-membership menu on a conversation/contact; they must return only
# pipelines the caller may see (public + own + default + team), and creating a `team`
# pipeline must persist the picker's team_ids (previously discarded). We WebMock evo-auth
# so `pipelines.{read,create}` gates the endpoints and Current.user resolves to the caller.
RSpec.describe 'Api::V1::Pipelines team visibility (EVO-2222)', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:token) { 'test-bearer-token' }

  let!(:owner) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let!(:member) { User.create!(name: 'Member', email: "member-#{SecureRandom.hex(4)}@example.com") }
  let!(:outsider) { User.create!(name: 'Outsider', email: "out-#{SecureRandom.hex(4)}@example.com") }
  let(:team) { Team.create!(name: "Team #{SecureRandom.hex(4)}") }

  let(:team_pipeline) do
    Pipeline.create!(name: "Team #{SecureRandom.hex(4)}", pipeline_type: 'custom',
                     visibility: :team, created_by: owner, teams: [team]).tap do |p|
      p.pipeline_stages.create!(name: 'New', position: 1)
    end
  end
  let(:public_pipeline) do
    Pipeline.create!(name: "Public #{SecureRandom.hex(4)}", pipeline_type: 'support',
                     visibility: :public, created_by: owner).tap do |p|
      p.pipeline_stages.create!(name: 'New', position: 1)
    end
  end
  let(:contact) { Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@example.com") }

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

  def json_response
    response.parsed_body
  end

  def headers
    { 'Authorization' => "Bearer #{token}" }
  end

  # Resolve Current.user to `user` and grant the given permission keys.
  def stub_auth(user, granted:)
    stub_request(:post, "#{base_url}/api/v1/auth/validate")
      .to_return(status: 200,
                 body: { success: true,
                         data: { user: { id: user.id, email: user.email, role: { id: 1, key: 'r', name: 'r' } } } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |req|
        key = JSON.parse(req.body)['permission_key']
        { status: 200, body: { success: true, data: { has_permission: granted.include?(key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' } }
      end
  end

  def place_on(pipeline)
    pipeline.pipeline_items.create!(contact: contact, pipeline_stage: pipeline.pipeline_stages.first,
                                    entered_at: Time.current)
  end

  describe 'GET /api/v1/pipelines/by_contact/:contact_id' do
    before do
      team.team_members.create!(user: member)
      place_on(team_pipeline)
      place_on(public_pipeline)
    end

    def by_contact(as_user)
      stub_auth(as_user, granted: %w[pipelines.read])
      get "/api/v1/pipelines/by_contact/#{contact.id}", headers: headers, as: :json
    end

    it 'shows a team pipeline to a member of its team (AC3)' do
      by_contact(member)
      expect(response).to have_http_status(:ok)
      ids = json_response['data'].map { |p| p['id'] }
      expect(ids).to include(team_pipeline.id, public_pipeline.id)
    end

    it 'hides the team pipeline from a non-member, keeping the public one (AC3)' do
      by_contact(outsider)
      expect(response).to have_http_status(:ok)
      ids = json_response['data'].map { |p| p['id'] }
      expect(ids).to include(public_pipeline.id)
      expect(ids).not_to include(team_pipeline.id)
    end
  end

  describe 'POST /api/v1/pipelines' do
    it 'persists team_ids for a team pipeline instead of discarding them (AC1)' do
      stub_auth(owner, granted: %w[pipelines.create])

      post '/api/v1/pipelines',
           params: { pipeline: { name: "New #{SecureRandom.hex(4)}", pipeline_type: 'custom',
                                 visibility: 'team', team_ids: [team.id] } },
           headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(json_response['data']['team_ids']).to contain_exactly(team.id)
      expect(Pipeline.find(json_response['data']['id']).team_ids).to contain_exactly(team.id)
    end
  end
end
