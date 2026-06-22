# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# T4.4 — AssignableAgentsController restricts the requested inboxes to the
# caller's accessible inboxes (assigned_inboxes) and filters out inaccessible
# ones GRACEFULLY (no 403). `User.with_role` is an enterprise-provided method
# absent in Community, so we stub it to isolate the new scoping logic.
RSpec.describe 'Api::V1::AssignableAgents inbox scoping', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let!(:user) { User.create!(name: 'Scoped User', email: "scoped-#{SecureRandom.hex(4)}@example.com") }
  let!(:member) { User.create!(name: 'Member', email: "member-#{SecureRandom.hex(4)}@example.com") }
  let!(:inbox_a) { Inbox.create!(channel: Channel::Api.create!, name: 'AAA Inbox') }
  let!(:inbox_b) { Inbox.create!(channel: Channel::Api.create!, name: 'BBB Inbox') }

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
    # member is assignable on both inboxes
    InboxMember.create!(inbox: inbox_a, user: member)
    InboxMember.create!(inbox: inbox_b, user: member)
    # caller is restricted to inbox A only
    InboxMember.create!(inbox: inbox_a, user: user)

    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { user: { id: user.id, email: user.email, role: { id: 1, key: 'agent_restricted', name: 'agent_restricted' } } }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
    # No conversations.read_all granted.
    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return(status: 200, body: { success: true, data: { has_permission: false } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  def json_response
    JSON.parse(response.body)
  end

  it 'drops inboxes the caller cannot access instead of raising 403' do
    get '/api/v1/assignable_agents',
        params: { inbox_ids: [inbox_a.id, inbox_b.id] },
        headers: headers

    # inbox_b is filtered out (caller restricted to A) — no 403. The agents are
    # the members of the accessible inbox A: `member` AND the caller `user`
    # (also an inbox_member of A). inbox_b's members never count.
    expect(response).to have_http_status(:ok)
    expect(json_response['data'].map { |u| u['id'] }).to contain_exactly(member.id, user.id)
  end

  it 'returns an empty agent list (not 500) when no requested inbox is accessible' do
    get '/api/v1/assignable_agents',
        params: { inbox_ids: [inbox_b.id] },
        headers: headers

    expect(response).to have_http_status(:ok)
    expect(json_response['data']).to eq([])
  end
end
