# frozen_string_literal: true

require 'rails_helper'
# `evo_core_api_keys` is owned by the Go service and absent from db/schema.rb.
# Without it, `imported_credentials?` raises inside the example's transaction,
# the rescue swallows it, and every later query answers
# PG::InFailedSqlTransaction — so an unstubbed example would pass while proving
# nothing about the guard.
require Rails.root.join('spec/support/evo_core_api_keys_table')

# The "in use" panel must not guess whether the legacy fallback still serves:
# only Ai::MigrationState knows, so it is exposed as a boolean behind the same
# read permission the screen itself demands.
RSpec.describe 'AI credentials migration state', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }

  # rubocop:disable RSpec/BeforeAfterAll -- creating the table is DDL, which
  # cannot run inside the per-example transaction.
  before(:all) { EvoCoreApiKeysTable.create! }
  after(:all) { EvoCoreApiKeysTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

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

  def stub_global_openai_secret(value)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return(value)
  end

  describe 'GET /api/v1/ai_credentials/migration_state' do
    it 'denies a user without ai_api_keys.read' do
      grant_permissions('ai_agents.read')

      get '/api/v1/ai_credentials/migration_state', as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'reports the fallback alive while the install has not migrated' do
      grant_permissions('ai_api_keys.read')
      allow(Ai::MigrationState).to receive(:migrated?).and_return(false)

      get '/api/v1/ai_credentials/migration_state', as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['data']).to eq('migrated' => false, 'legacy_fallback_active' => true)
    end

    it 'never carries a key, only the two booleans' do
      grant_permissions('ai_api_keys.read')
      allow(Ai::MigrationState).to receive(:migrated?).and_return(true)

      get '/api/v1/ai_credentials/migration_state', as: :json

      expect(response.parsed_body['data'].keys).to contain_exactly('migrated', 'legacy_fallback_active')
    end

    # No stub on the guard in the four examples below: each pins one corner of
    # `migrated? = imported_credentials? || legacy_sources_empty?`. Stubbing
    # `migrated?` here would only prove the controller can serialize a boolean —
    # hardwiring either half to false (the CRM-187 bug at its source) would stay
    # green.
    context 'with the guard unstubbed' do
      before { grant_permissions('ai_api_keys.read') }

      it 'reports migrated when no legacy source exists anywhere' do
        get '/api/v1/ai_credentials/migration_state', as: :json

        expect(response.parsed_body['data']).to eq('migrated' => true, 'legacy_fallback_active' => false)
      end

      it 'reports the fallback alive while the global secret still holds a key' do
        stub_global_openai_secret('sk-legacy-1234')

        get '/api/v1/ai_credentials/migration_state', as: :json

        expect(response.parsed_body['data']).to eq('migrated' => false, 'legacy_fallback_active' => true)
      end

      it 'reports the fallback alive while the openai hook still holds a key' do
        allow(Integrations::Hook).to receive(:find_by)
          .with(app_id: 'openai')
          .and_return(instance_double(Integrations::Hook, settings: { 'api_key' => 'sk-hook-1234' }))

        get '/api/v1/ai_credentials/migration_state', as: :json

        expect(response.parsed_body['data']).to eq('migrated' => false, 'legacy_fallback_active' => true)
      end

      # The 1.5 import task is the other way in: once a credential carries
      # `imported_from`, the fallback is dead even though a legacy source is
      # still lying around.
      it 'reports migrated once an imported credential exists despite a live legacy source' do
        Ai::Credential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
          [{ name: 'imported', provider: 'openai', key: 'ciphertext', key_hint: '1234',
             scope: 'account', imported_from: 'global',
             created_at: Time.current, updated_at: Time.current }]
        )
        stub_global_openai_secret('sk-legacy-1234')

        get '/api/v1/ai_credentials/migration_state', as: :json

        expect(response.parsed_body['data']).to eq('migrated' => true, 'legacy_fallback_active' => false)
      end
    end
  end
end
