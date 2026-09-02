# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_api_keys_table')

# the guard that keeps retiring the fallback from switching
# AI off on an installation that never migrated.
RSpec.describe Ai::MigrationState do
  let(:fernet_key) { 'XoQPOBw2FrzjQS11utERG9qO2MsAnXFxlhIns_uUxRk=' }

  # rubocop:disable RSpec/BeforeAfterAll -- creating the table is DDL, which
  # cannot run inside the per-example transaction.
  before(:all) { EvoCoreApiKeysTable.create! }
  after(:all) { EvoCoreApiKeysTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  around do |example|
    original = ENV.fetch('EVO_AI_ENCRYPTION_KEY', nil)
    ENV['EVO_AI_ENCRYPTION_KEY'] = fernet_key
    example.run
    ENV['EVO_AI_ENCRYPTION_KEY'] = original
  end

  before do
    Ai::Credential.delete_all
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return(nil)
    allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(nil)
  end

  def register(imported_from: nil)
    Ai::Credential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: "cred-#{SecureRandom.hex(4)}", provider: 'openai',
        key: Ai::CredentialEncryptor.encrypt('sk-registry-1111'), key_hint: '1111',
        scope: 'account', is_active: true, imported_from: imported_from,
        created_at: Time.current, updated_at: Time.current
      }]
    )
  end

  def with_legacy_global(key)
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return(key)
  end

  describe '.migrated?' do
    it 'is true once the 1.5 task imported something' do
      register(imported_from: Ai::CredentialMigration::INSTALLATION_SOURCE)
      with_legacy_global('sk-legacy-9999')

      expect(described_class).to be_migrated
    end

    it 'is true on a fresh install with nothing in the legacy sources' do
      # Never had a key anywhere: there is nothing to migrate, so retiring the
      # fallback takes nothing away.
      expect(described_class).to be_migrated
    end

    it 'is FALSE when a legacy key exists and nothing was imported' do
      with_legacy_global('sk-legacy-9999')

      expect(described_class).not_to be_migrated
    end

    it 'is false when the legacy key lives in the hook' do
      hook = instance_double(Integrations::Hook, settings: { 'api_key' => 'sk-hook-8888' })
      allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(hook)

      expect(described_class).not_to be_migrated
    end

    it 'does not count a hand-registered credential as a migration' do
      # A human registering a credential on the new screen does not prove the
      # legacy key was carried over — the fallback must stay.
      register(imported_from: nil)
      with_legacy_global('sk-legacy-9999')

      expect(described_class).not_to be_migrated
    end

    it 'treats a database failure as NOT migrated' do
      allow(Ai::Credential).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'boom')
      with_legacy_global('sk-legacy-9999')

      # Reading an error as "migrated" would remove the fallback on a broken
      # install, which is the one thing this guard exists to prevent.
      expect(described_class).not_to be_migrated
    end
  end

  describe 'the resolver honours the guard (AC3, AC4)' do
    it 'still serves the legacy key while the install has not migrated' do
      with_legacy_global('sk-legacy-9999')

      expect(Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist)).to eq('sk-legacy-9999')
    end

    it 'warns, so the operator knows which task to run' do
      with_legacy_global('sk-legacy-9999')
      allow(Rails.logger).to receive(:warn)

      Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist)

      expect(Rails.logger).to have_received(:warn).with(/ai_credentials:migrate/)
    end

    it 'stops reading the legacy source once the install migrated' do
      register(imported_from: Ai::CredentialMigration::INSTALLATION_SOURCE)
      Ai::Credential.update_all(is_active: false) # rubocop:disable Rails/SkipsModelValidations
      with_legacy_global('sk-legacy-9999')

      # Migrated: the registry is the only origin, so an inactive registry
      # credential means "nothing configured", not "fall back to the old key".
      expect(Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist)).to be_nil
    end

    it 'serves the registry credential after migrating' do
      register(imported_from: Ai::CredentialMigration::INSTALLATION_SOURCE)
      with_legacy_global('sk-legacy-9999')

      expect(Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist)).to eq('sk-registry-1111')
    end
  end
end
