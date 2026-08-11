# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-2222 — `team` pipeline visibility, end-to-end through the gate. The by_* endpoints
# feed the pipeline-membership menu on a conversation/contact; they must return only
# pipelines the caller may see (public + own + default + team), and create/update must
# persist the picker's team_ids. We WebMock evo-auth so `pipelines.{read,create,update}`
# gates the endpoints and Current.user resolves to the caller.
#
# The write examples send the payload BARE, with no `pipeline` envelope: that is what the
# client posts, and the envelope would switch ParamsWrapper off, taking the gap with it.
RSpec.describe 'Api::V1::Pipelines team visibility (EVO-2222)', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:token) { 'test-bearer-token' }
  let(:service_token) { 'test-service-token' }

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

  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(4)}", channel: channel) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  around do |example|
    original = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    original_service_token = ENV.fetch('EVOAI_CRM_API_TOKEN', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original
    ENV['EVOAI_CRM_API_TOKEN'] = original_service_token
  end

  def json_response
    response.parsed_body
  end

  def headers
    { 'Authorization' => "Bearer #{token}" }
  end

  def service_headers
    { 'X-Service-Token' => service_token }
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

  def place_on(pipeline, on: :contact)
    attrs = { pipeline_stage: pipeline.pipeline_stages.first, entered_at: Time.current }
    attrs[on] = on == :contact ? contact : conversation
    pipeline.pipeline_items.create!(attrs)
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

    # Internal callers carry no Current.user; scoping by nil would answer with a
    # silently partial list.
    it 'does not scope a service-to-service call' do
      get "/api/v1/pipelines/by_contact/#{contact.id}", headers: service_headers, as: :json

      expect(response).to have_http_status(:ok)
      ids = json_response['data'].map { |p| p['id'] }
      expect(ids).to include(team_pipeline.id, public_pipeline.id)
    end
  end

  # Same scoping helper as by_contact, reached from the conversation side.
  describe 'GET /api/v1/pipelines/by_conversation/:conversation_id' do
    before do
      team.team_members.create!(user: member)
      place_on(team_pipeline, on: :conversation)
      place_on(public_pipeline, on: :conversation)
    end

    def by_conversation(as_user)
      stub_auth(as_user, granted: %w[pipelines.read])
      get "/api/v1/pipelines/by_conversation/#{conversation.id}", headers: headers, as: :json
    end

    it 'shows a team pipeline to a member of its team (AC3)' do
      by_conversation(member)
      expect(response).to have_http_status(:ok)
      ids = json_response['data'].map { |p| p['id'] }
      expect(ids).to include(team_pipeline.id, public_pipeline.id)
    end

    it 'hides the team pipeline from a non-member, keeping the public one (AC3)' do
      by_conversation(outsider)
      expect(response).to have_http_status(:ok)
      ids = json_response['data'].map { |p| p['id'] }
      expect(ids).to include(public_pipeline.id)
      expect(ids).not_to include(team_pipeline.id)
    end
  end

  describe 'POST /api/v1/pipelines' do
    before { stub_auth(owner, granted: %w[pipelines.write]) }

    def create_pipeline(payload)
      post '/api/v1/pipelines', params: payload, headers: headers, as: :json
    end

    it 'persists team_ids sent without the pipeline envelope, as the client sends them (AC1)' do
      create_pipeline(name: "New #{SecureRandom.hex(4)}", pipeline_type: 'custom',
                      visibility: 'team', team_ids: [team.id])

      expect(response).to have_http_status(:created)
      expect(json_response['data']['team_ids']).to contain_exactly(team.id)
      expect(Pipeline.find(json_response['data']['id']).team_ids).to contain_exactly(team.id)
    end

    it 'persists team_ids sent inside the pipeline envelope (AC1)' do
      create_pipeline(pipeline: { name: "New #{SecureRandom.hex(4)}", pipeline_type: 'custom',
                                  visibility: 'team', team_ids: [team.id] })

      expect(response).to have_http_status(:created)
      expect(json_response['data']['team_ids']).to contain_exactly(team.id)
      expect(Pipeline.find(json_response['data']['id']).team_ids).to contain_exactly(team.id)
    end
  end

  describe 'PATCH /api/v1/pipelines/:id' do
    let(:pipeline) do
      Pipeline.create!(name: "Editable #{SecureRandom.hex(4)}", pipeline_type: 'custom',
                       visibility: :private, created_by: owner)
    end

    before { stub_auth(owner, granted: %w[pipelines.write]) }

    def update_pipeline(payload)
      patch "/api/v1/pipelines/#{pipeline.id}", params: payload, headers: headers, as: :json
    end

    it 'persists team_ids sent without the pipeline envelope, as the client sends them (AC1)' do
      update_pipeline(visibility: 'team', team_ids: [team.id])

      expect(response).to have_http_status(:ok)
      expect(json_response['data']['team_ids']).to contain_exactly(team.id)
      expect(pipeline.reload.team_ids).to contain_exactly(team.id)
    end

    it 'clears the selection on an explicit empty list' do
      pipeline.update!(visibility: :team, team_ids: [team.id])

      update_pipeline(visibility: 'team', team_ids: [])

      expect(response).to have_http_status(:ok)
      expect(json_response['data']['team_ids']).to be_empty
      expect(pipeline.reload.team_ids).to be_empty
    end

    it 'leaves the selection untouched when team_ids is not sent at all' do
      pipeline.update!(visibility: :team, team_ids: [team.id])

      update_pipeline(name: "Renamed #{SecureRandom.hex(4)}")

      expect(response).to have_http_status(:ok)
      expect(pipeline.reload.team_ids).to contain_exactly(team.id)
    end

    it 'makes the pipeline reachable by the team members it was just shared with (AC2)' do
      team.team_members.create!(user: member)

      update_pipeline(visibility: 'team', team_ids: [team.id])

      expect(Pipeline.accessible_by(member)).to include(pipeline)
      expect(Pipeline.accessible_by(outsider)).not_to include(pipeline)
    end
  end
end
