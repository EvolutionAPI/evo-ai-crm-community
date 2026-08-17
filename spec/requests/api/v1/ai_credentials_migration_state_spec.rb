# frozen_string_literal: true

require 'rails_helper'

# The "in use" panel must not guess whether the legacy fallback still serves:
# only Ai::MigrationState knows, so it is exposed as a boolean behind the same
# read permission the screen itself demands.
RSpec.describe 'AI credentials migration state', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
  end

  after { Current.reset }

  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  describe 'GET /api/v1/ai/credentials/migration_state' do
    it 'denies a user without ai_api_keys.read' do
      grant_permissions('ai_agents.read')

      get '/api/v1/ai/credentials/migration_state', as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'reports the fallback alive while the install has not migrated' do
      grant_permissions('ai_api_keys.read')
      allow(Ai::MigrationState).to receive(:migrated?).and_return(false)

      get '/api/v1/ai/credentials/migration_state', as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['data']).to eq('migrated' => false, 'legacy_fallback_active' => true)
    end

    it 'reports the fallback dead once the install migrated' do
      grant_permissions('ai_api_keys.read')
      allow(Ai::MigrationState).to receive(:migrated?).and_return(true)

      get '/api/v1/ai/credentials/migration_state', as: :json

      expect(response.parsed_body['data']).to eq('migrated' => true, 'legacy_fallback_active' => false)
    end

    # No stub on the guard: the real legacy sources decide, so the wiring to
    # Ai::MigrationState is exercised end to end.
    it 'derives the answer from the real legacy sources' do
      grant_permissions('ai_api_keys.read')
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return('sk-legacy-1234')
      allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(nil)

      get '/api/v1/ai/credentials/migration_state', as: :json

      expect(response.parsed_body['data']).to eq('migrated' => false, 'legacy_fallback_active' => true)
    end

    it 'never carries a key, only the two booleans' do
      grant_permissions('ai_api_keys.read')
      allow(Ai::MigrationState).to receive(:migrated?).and_return(true)

      get '/api/v1/ai/credentials/migration_state', as: :json

      expect(response.parsed_body['data'].keys).to contain_exactly('migrated', 'legacy_fallback_active')
    end
  end
end
