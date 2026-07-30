# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_api_keys_table')

# the legacy chain as the last link of the resolver.
#
# The pre-registry precedence (global config wins, account hook is the fallback)
# did not disappear: it dropped one level. What changes is that the registry is
# tried first, so a credential registered on the new screen is never shadowed by
# legacy configuration.
RSpec.describe Ai::CredentialResolver, '.resolve_key' do
  # Same frozen fixtures as credential_decryptor_spec: ciphertext produced by the
  # Go service. `let` avoids redefining the constants that spec declares.
  let(:fernet_key) { 'XoQPOBw2FrzjQS11utERG9qO2MsAnXFxlhIns_uUxRk=' }
  let(:go_ciphertext) do
    'gAAAAABqagvYo5FEA9quumGpPOgNwZMRVyKb5uFhsibgflYMUC5vdSCbbEdvdV4etg3_' \
      'CtQekqXPOtsIESs2aRluGJrCNy9rAxpiusgJdRoQ0EdVJIjsSdY='
  end
  let(:go_plaintext) { 'sk-proj-real-secret-4f2a' }

  # rubocop:disable RSpec/BeforeAfterAll -- creating the table is DDL, which
  # cannot run inside the per-example transaction. Shared helper so every spec
  # agrees on the column set.
  before(:all) { EvoCoreApiKeysTable.create! }
  after(:all) { EvoCoreApiKeysTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  around do |example|
    original = ENV.fetch('EVO_AI_ENCRYPTION_KEY', nil)
    ENV['EVO_AI_ENCRYPTION_KEY'] = fernet_key
    example.run
    ENV['EVO_AI_ENCRYPTION_KEY'] = original
  end

  before { Ai::Credential.delete_all }

  def register(scope:, ciphertext:, provider: 'openai', active: true)
    Ai::Credential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: "cred-#{scope}-#{provider}",
        provider: provider,
        key: ciphertext,
        key_hint: '4f2a',
        scope: scope,
        is_active: active,
        created_at: Time.current,
        updated_at: Time.current
      }]
    )
  end

  describe 'the registry wins over legacy sources (AC4)' do
    it 'ignores the global config when the registry has a credential' do
      register(scope: 'account', ciphertext: go_ciphertext)
      allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return('sk-legacy-global')

      expect(described_class.resolve_key(for_consumer: :inbox_assist)).to eq(go_plaintext)
    end

    it 'ignores the account hook when the registry has a credential' do
      register(scope: 'installation', ciphertext: go_ciphertext)
      hook = instance_double(Integrations::Hook, settings: { 'api_key' => 'sk-legacy-hook' })

      expect(
        described_class.resolve_key(for_consumer: :inbox_assist, legacy_hook: hook)
      ).to eq(go_plaintext)
    end
  end

  describe 'unmigrated installations keep working (AC3)' do
    it 'falls back to the global config when the registry is empty' do
      allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return('sk-legacy-global')

      expect(described_class.resolve_key(for_consumer: :inbox_assist)).to eq('sk-legacy-global')
    end

    it 'falls back to the hook when neither registry nor global config has one' do
      allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return(nil)
      hook = instance_double(Integrations::Hook, settings: { 'api_key' => 'sk-legacy-hook' })

      expect(
        described_class.resolve_key(for_consumer: :inbox_assist, legacy_hook: hook)
      ).to eq('sk-legacy-hook')
    end

    it 'preserves the legacy order between the two: global beats hook' do
      allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return('sk-legacy-global')
      hook = instance_double(Integrations::Hook, settings: { 'api_key' => 'sk-legacy-hook' })

      expect(
        described_class.resolve_key(for_consumer: :inbox_assist, legacy_hook: hook)
      ).to eq('sk-legacy-global')
    end

    it 'falls back when the registry credential cannot be decrypted' do
      register(scope: 'account', ciphertext: 'not-a-fernet-token')
      allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return('sk-legacy-global')

      expect(described_class.resolve_key(for_consumer: :inbox_assist)).to eq('sk-legacy-global')
    end
  end

  describe 'incompatible providers never reach the wire (AC5)' do
    it 'skips an Anthropic account credential and inherits the installation one' do
      register(scope: 'account', provider: 'anthropic', ciphertext: go_ciphertext)
      register(scope: 'installation', ciphertext: go_ciphertext)

      expect(described_class.resolve_key(for_consumer: :inbox_assist)).to eq(go_plaintext)
    end

    it 'does not offer a non-OpenAI credential to the legacy chain either' do
      register(scope: 'account', provider: 'anthropic', ciphertext: go_ciphertext)
      allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return('sk-legacy-global')

      # The assist speaks the OpenAI protocol, so it still gets a usable key
      # from the legacy chain rather than the Anthropic one.
      expect(described_class.resolve_key(for_consumer: :inbox_assist)).to eq('sk-legacy-global')
    end
  end

  describe 'nothing configured anywhere (AC6)' do
    it 'returns nil without raising' do
      allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return(nil)

      expect { described_class.resolve_key(for_consumer: :inbox_assist) }.not_to raise_error
      expect(described_class.resolve_key(for_consumer: :inbox_assist)).to be_nil
    end
  end

  describe 'AI Agents are not restricted to the legacy OpenAI chain' do
    it 'resolves an Anthropic credential for agents' do
      register(scope: 'account', provider: 'anthropic', ciphertext: go_ciphertext)

      expect(described_class.resolve_key(for_consumer: :ai_agents)).to eq(go_plaintext)
    end
  end
end
