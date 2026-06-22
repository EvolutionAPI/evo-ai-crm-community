# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# Covers the per-inbox granularity established by the RBAC-granular feature:
# T4.0 (Current.evo_can_read_all_inboxes), T4.1 (User#assigned_inboxes),
# T4.2 (InboxesController#index scoping) and T4.3 (InboxPolicy#show?).
#
# The whole chain is exercised end-to-end through the bearer-auth path: we
# WebMock-stub evo-auth's /validate (carries role.key) and /check_permission
# (carries conversations.read_all and inboxes.read), then assert the scoped list.
RSpec.describe 'Api::V1::Inboxes inbox scoping', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let!(:user) { User.create!(name: 'Scoped User', email: "scoped-#{SecureRandom.hex(4)}@example.com") }
  let!(:inbox_a) { Inbox.create!(channel: Channel::Api.create!, name: 'AAA Inbox') }
  let!(:inbox_b) { Inbox.create!(channel: Channel::Api.create!, name: 'BBB Inbox') }
  let!(:inbox_c) { Inbox.create!(channel: Channel::Api.create!, name: 'CCC Inbox') }

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

  def json_response
    JSON.parse(response.body)
  end

  # Stubs /validate to return the given role key, and /check_permission for the
  # given user to answer `true` only for the permission keys in `granted`.
  def stub_auth(role_key:, granted: [])
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { user: { id: user.id, email: user.email, role: { id: 1, key: role_key, name: role_key } } }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        permission_key = JSON.parse(request.body)['permission_key']
        {
          status: 200,
          body: { success: true, data: { has_permission: granted.include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  def returned_inbox_ids
    json_response['data'].map { |i| i['id'] }
  end

  describe 'GET /api/v1/inboxes' do
    context 'when the user is restricted (no read_all) and assigned only to inbox A (AC9)' do
      before do
        InboxMember.create!(inbox: inbox_a, user: user)
        stub_auth(role_key: 'agent_restricted', granted: %w[inboxes.read])
      end

      it 'returns only the assigned inbox' do
        get '/api/v1/inboxes', headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(returned_inbox_ids).to contain_exactly(inbox_a.id)
      end
    end

    context 'when the user has no inbox assignment and no read_all (AC11 — opt-in default)' do
      before { stub_auth(role_key: 'agent_restricted', granted: %w[inboxes.read]) }

      it 'returns all inboxes' do
        get '/api/v1/inboxes', headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(returned_inbox_ids).to contain_exactly(inbox_a.id, inbox_b.id, inbox_c.id)
      end
    end

    context 'when the user has conversations.read_all (AC12 — system agent)' do
      before do
        # Assigned only to A, but read_all overrides the restriction.
        InboxMember.create!(inbox: inbox_a, user: user)
        stub_auth(role_key: 'agent', granted: %w[inboxes.read conversations.read_all])
      end

      it 'returns all inboxes despite the single assignment' do
        get '/api/v1/inboxes', headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(returned_inbox_ids).to contain_exactly(inbox_a.id, inbox_b.id, inbox_c.id)
      end
    end

    context 'when the user is an admin (AC13)' do
      before do
        # Assigned only to A and explicitly NOT granted read_all — admin bypasses both.
        InboxMember.create!(inbox: inbox_a, user: user)
        stub_auth(role_key: 'super_admin', granted: %w[inboxes.read])
      end

      it 'returns all inboxes and never hits the remote read_all check' do
        get '/api/v1/inboxes', headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(returned_inbox_ids).to contain_exactly(inbox_a.id, inbox_b.id, inbox_c.id)
        # Admin short-circuits before any conversations.read_all remote call (T4.0).
        expect(
          a_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
            .with(body: hash_including('permission_key' => 'conversations.read_all'))
        ).not_to have_been_made
      end
    end
  end

  describe 'GET /api/v1/inboxes/:id (InboxPolicy#show? — T4.3)' do
    context 'when restricted to inbox A' do
      before do
        InboxMember.create!(inbox: inbox_a, user: user)
        stub_auth(role_key: 'agent_restricted', granted: %w[inboxes.read])
      end

      it 'allows showing the assigned inbox' do
        get "/api/v1/inboxes/#{inbox_a.id}", headers: headers, as: :json
        expect(response).to have_http_status(:ok)
      end

      it 'denies showing a non-assigned inbox (no more inboxes.read bypass)' do
        get "/api/v1/inboxes/#{inbox_b.id}", headers: headers, as: :json
        # T4.3 makes InboxPolicy#show? deny non-assigned inboxes (previously dead
        # code because the inboxes.read bypass always passed via the stub).
        # NOTE: the denial surfaces as 401, not 403, because RequestExceptionHandler's
        # `around_action :handle_with_exception` (ApplicationController) catches
        # Pundit::NotAuthorizedError and renders 401 BEFORE Api::BaseController's
        # rescue_from (which would render 403) can run. Pre-existing status-semantics
        # bug, never exercised for inboxes until show? actually denied. Follow-up:
        # reconcile the two Pundit handlers to return 403. The assertion here is
        # that access IS denied for a non-assigned inbox.
        expect(response).to have_http_status(:unauthorized)
        expect(response).not_to have_http_status(:ok)
      end
    end
  end
end
