# frozen_string_literal: true

require 'rails_helper'

# Negative proof for CRM-190 — the hardened default `agent` role must be BLOCKED
# on deleting shared, account-wide assets (labels/macros/canned_responses/
# message_templates) while keeping read/create/update and macros.execute. evo-auth
# stops seeding the *.delete keys; these are the CRM-side gates that enforce it.
#
# Every example grants exactly AGENT_KEYS — the asset set the agent keeps after
# CRM-190 — so a regression that re-maps any destroy to a key the agent still holds
# (or drops the gate) turns an example red. The destroy gates fire before the record
# is fetched, so a non-existent id still 403s (proving the gate, not a 404).
RSpec.describe 'Agent shared-asset deletes RBAC (CRM-190)', type: :request do
  # What the default `agent` keeps after CRM-190: read/create/update of each shared
  # asset + macros.execute, but NONE of the *.delete keys.
  AGENT_ASSET_KEYS = %w[
    labels.read labels.create labels.update
    canned_responses.read canned_responses.create canned_responses.update
    message_templates.read message_templates.create message_templates.update
    macros.read macros.create macros.update macros.execute
  ].freeze

  let(:user) { User.create!(name: 'Agent Probe', email: "agent-#{SecureRandom.hex(4)}@example.com") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    # Model the real hardened agent: it holds AGENT_ASSET_KEYS and nothing else.
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      AGENT_ASSET_KEYS.include?(permission)
    end
  end

  after { Current.reset }

  # --- Destroy of a shared asset must be blocked (403) ---

  {
    'labels' => 'labels.delete',
    'macros' => 'macros.delete',
    'canned_responses' => 'canned_responses.delete',
    'message_templates' => 'message_templates.delete'
  }.each do |resource, key|
    describe "DELETE /api/v1/#{resource}/:id (#{key})" do
      it 'denies the hardened agent (gate fires before the record is fetched)' do
        delete "/api/v1/#{resource}/#{SecureRandom.uuid}", as: :json

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # --- Reads the agent keeps (200) ---

  %w[macros canned_responses message_templates labels].each do |resource|
    describe "GET /api/v1/#{resource}" do
      it 'lists for the hardened agent' do
        get "/api/v1/#{resource}", as: :json

        expect(response).to have_http_status(:ok)
      end
    end
  end

  # --- macros.execute stays attendance (gate passes) ---

  describe 'POST /api/v1/macros/:id/execute (macros.execute)' do
    it 'is not blocked for the hardened agent (holds macros.execute)' do
      post "/api/v1/macros/#{SecureRandom.uuid}/execute", params: { conversation_id: SecureRandom.uuid }, as: :json

      # The permission gate must let it through; a missing macro then 404s. The
      # point is that macros.execute is NOT revoked, so the response is never 403.
      expect(response).not_to have_http_status(:forbidden)
    end
  end
end
