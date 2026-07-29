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
end
