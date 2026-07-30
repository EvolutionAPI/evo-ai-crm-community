# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_api_keys_table')

# Adversarial review of story 1.5 (EVO-2250).
RSpec.describe Ai::CredentialMigration do
  # rubocop:disable RSpec/BeforeAfterAll -- DDL cannot run inside the per-example transaction.
  before(:all) { EvoCoreApiKeysTable.create! }
  after(:all) { EvoCoreApiKeysTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  before do
    Ai::Credential.delete_all
    Integrations::Hook.delete_all
    InstallationConfig.find_by(name: 'OPENAI_API_SECRET')&.destroy!
    GlobalConfig.clear_cache
    allow(Ai::CredentialDecryptor).to receive(:encryption_key).and_return(fernet_key)
  end

  let(:fernet_key) { 'cw_0x689RpI-jtRR7oE8h_eQsKImvJapLeSbXpwF4e4=' }

  # `imported_from` is VARCHAR(64) (migration 000018). A hook source built from a
  # real uuid is 62 chars, and the ":original" variant is 71: on any install with
  # BOTH a global key and a hook, the migration used to insert the account row and
  # then blow up on the inactive one, leaving a partial write behind.
  it 'keeps every import source within the column limit' do
    hook = Integrations::Hook.create!(app_id: 'openai', status: 'enabled', settings: { 'api_key' => 'sk-do-hook' })

    sources = [
      described_class::INSTALLATION_SOURCE,
      "#{described_class::HOOK_SOURCE_PREFIX}#{hook.id}",
      "#{described_class::HOOK_SOURCE_PREFIX}#{hook.id}:original"
    ]

    sources.each do |source|
      expect(source.length).to be <= 64, "import source #{source.inspect} has #{source.length} chars, column holds 64"
    end
  end

  it 'imports a global key plus a hook without raising' do
    InstallationConfig.create!(name: 'OPENAI_API_SECRET', value: 'sk-global', locked: false)
    GlobalConfig.clear_cache
    Integrations::Hook.create!(app_id: 'openai', status: 'enabled', settings: { 'api_key' => 'sk-do-hook' })

    expect { described_class.call(apply: true) }.not_to raise_error

    # Both the promoted account row and the preserved original must land.
    expect(Ai::Credential.where.not(imported_from: nil).count).to eq(3)
  end

  # A partial write is worse than no write: it flips MigrationState to "migrated"
  # and the 1.6 guard then removes the legacy fallback for consumers whose
  # credential never made it into the registry.
  it 'writes nothing when an import fails midway' do
    InstallationConfig.create!(name: 'OPENAI_API_SECRET', value: 'sk-global', locked: false)
    GlobalConfig.clear_cache
    Integrations::Hook.create!(app_id: 'openai', status: 'enabled', settings: { 'api_key' => 'sk-do-hook' })

    # The installation row imports fine; the hook import then blows up.
    call_count = 0
    allow(Ai::CredentialEncryptor).to receive(:encrypt).and_wrap_original do |original, *args|
      call_count += 1
      raise ActiveRecord::ValueTooLong, 'boom' if call_count > 1

      original.call(*args)
    end

    expect { described_class.call(apply: true) }.to raise_error(ActiveRecord::ValueTooLong)
    expect(Ai::Credential.count).to eq(0), 'a partial write survived and would flip the migration guard'
  end

  # ALTO 6 of the review: the gate disarmed itself.
  #
  # `effective_after` returned `existing_registry_key` whenever ANY active
  # credential existed — literally the same call as `before_key` — so no row
  # could ever report DIVERGE. And the migration still inserts an `account` row,
  # which OUTRANKS an installation credential a human had registered: the
  # effective key changes while the report says OK. That is exactly the NFR the
  # gate exists to prove.
  describe 'the gate with a pre-existing human credential' do
    before do
      EvoCoreApiKeysTable.create!
      Ai::Credential.delete_all
      Ai::Credential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
        [{
          name: 'Cadastrada por humano', provider: 'openai',
          key: Ai::CredentialEncryptor.encrypt('sk-do-humano'),
          key_hint: 'mano', scope: 'installation', is_active: true,
          created_at: Time.current, updated_at: Time.current
        }]
      )
    end

    it 'aborts instead of letting an imported account row outrank it' do
      Integrations::Hook.create!(app_id: 'openai', status: 'enabled',
                                 settings: { 'api_key' => 'sk-do-hook' })

      expect { described_class.call(apply: true) }
        .to raise_error(described_class::AbortedError)

      expect(Ai::Credential.where.not(imported_from: nil).count).to eq(0),
                                                                    'the import wrote despite changing the effective key'
    end

    # The complement: with nothing to import the gate must not invent a
    # divergence and block a legitimate no-op run.
    it 'does not abort when there is nothing to import' do
      expect { described_class.call(apply: true) }.not_to raise_error
    end
  end

  # 1.5 AC1: the custom OPENAI_API_URL must be preserved ALONGSIDE the credential.
  # There was nowhere to put it until the core added the column (ae28fcd), so the
  # value the admin had configured was dropped on import.
  describe 'the custom base URL travels with the credential (AC1)' do
    before { Ai::Credential.delete_all }

    it 'stores a custom endpoint on the imported credential' do
      InstallationConfig.create!(name: 'OPENAI_API_SECRET', value: 'sk-global', locked: false)
      InstallationConfig.create!(name: 'OPENAI_API_URL', value: 'https://llm.interno.test/v1', locked: false)
      GlobalConfig.clear_cache

      described_class.call(apply: true)

      credential = Ai::Credential.find_by(scope: 'installation')
      expect(credential.base_url).to eq('https://llm.interno.test/v1')
    end

    # Stamping the public default on every install would be noise: NULL already
    # means "the provider default", which is what every pre-existing credential
    # meant.
    it 'leaves the column null when the endpoint is the public default' do
      InstallationConfig.create!(name: 'OPENAI_API_SECRET', value: 'sk-global', locked: false)
      InstallationConfig.create!(name: 'OPENAI_API_URL', value: 'https://api.openai.com/v1', locked: false)
      GlobalConfig.clear_cache

      described_class.call(apply: true)

      expect(Ai::Credential.find_by(scope: 'installation').base_url).to be_nil
    end

    it 'leaves the column null when no custom endpoint is configured' do
      InstallationConfig.create!(name: 'OPENAI_API_SECRET', value: 'sk-global', locked: false)
      GlobalConfig.clear_cache

      described_class.call(apply: true)

      expect(Ai::Credential.find_by(scope: 'installation').base_url).to be_nil
    end
  end
end
