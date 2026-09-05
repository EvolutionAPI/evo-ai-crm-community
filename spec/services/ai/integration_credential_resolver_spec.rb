# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_integration_credentials_table')

# `evo_core_integration_credentials` is created by the Go migration 000019 of
# evo-ai-core-service and is deliberately absent from `db/schema.rb`, so the
# test database has no such table. It is built here to exercise the resolver
# against the real column set instead of stubbing the model away.
RSpec.describe Ai::IntegrationCredentialResolver do
  # rubocop:disable RSpec/BeforeAfterAll -- creating the table is DDL, which
  # cannot run inside the per-example transaction.
  before(:all) { EvoCoreIntegrationCredentialsTable.create! }
  after(:all) { EvoCoreIntegrationCredentialsTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  before { Ai::IntegrationCredential.delete_all }

  def create_credential(name:, **options)
    kind = options.fetch(:kind, 'static')
    oauth = kind == Ai::IntegrationCredential::KIND_OAUTH

    # insert_all! is the point: the model is read-only, so the core service is
    # simulated writing straight to its own table.
    Ai::IntegrationCredential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: name,
        provider: options.fetch(:provider, 'dify'),
        kind: kind,
        value: options[:value] || (oauth ? nil : "ciphertext-#{name}"),
        value_format: 'scalar',
        value_hint: '9c1d',
        scope: options.fetch(:scope, 'account'),
        is_active: options.fetch(:active, true),
        owner_store: oauth ? 'agent_integration' : nil,
        owner_ref: oauth ? SecureRandom.uuid : nil,
        created_at: Time.current,
        updated_at: Time.current
      }]
    )
    Ai::IntegrationCredential.find_by(name: name)
  end

  describe 'resolution by reference (AC2)' do
    it 'returns exactly the referenced credential' do
      wanted = create_credential(name: 'Dify do time')
      create_credential(name: 'Outra qualquer', provider: 'n8n')

      expect(described_class.resolve_by_id(wanted.id)).to eq(wanted)
    end

    # AC2 is explicit: a reference that cannot be honoured resolves to nothing.
    # Falling through to the chain would silently authenticate against a
    # different platform than the one the consumer was configured with.
    it 'returns nothing for an inactive credential instead of falling through' do
      inactive = create_credential(name: 'Desativada', active: false)
      create_credential(name: 'Padrao da casa', scope: 'installation')

      expect(described_class.resolve_by_id(inactive.id)).to be_nil
    end

    it 'returns nothing for an unknown id instead of falling through' do
      create_credential(name: 'Padrao da casa', scope: 'installation')

      expect(described_class.resolve_by_id(SecureRandom.uuid)).to be_nil
    end

    it 'returns nothing for a blank id' do
      expect(described_class.resolve_by_id(nil)).to be_nil
      expect(described_class.resolve_by_id('')).to be_nil
    end
  end

  describe 'the ordered chain (AC1)' do
    after { Ai::ScopeChain.reset! }

    it 'declares scopes from the most generic to the most specific' do
      expect(Ai::ScopeChain.chain).to eq(%i[installation account])
    end

    # FR2 guard, same shape as story 1.2: an overlay inserts a link between
    # installation and account. Inserting a link must change precedence WITHOUT
    # editing the resolver — via the real insert_link port. Both resolvers walk
    # the one shared Ai::ScopeChain, so this reaching the integration resolver
    # proves the chain is not copied per class.
    it 'resolves a link inserted into the chain without any resolver change' do
      Ai::ScopeChain.insert_link(:agency, before: :account)
      create_credential(name: 'Da instalacao', scope: 'installation')
      agency = create_credential(name: 'Da agencia', scope: 'agency')

      expect(described_class.resolve_default(provider: 'dify')).to eq(agency)
    end

    it 'keeps honouring the most specific link when the new one is empty' do
      Ai::ScopeChain.insert_link(:agency, before: :account)
      create_credential(name: 'Da instalacao', scope: 'installation')
      account = create_credential(name: 'Da conta', scope: 'account')

      expect(described_class.resolve_default(provider: 'dify')).to eq(account)
    end
  end

  describe 'resolution by scope default (AC3, AC4, AC5, AC6)' do
    it 'falls back to the installation credential when the account has none (AC4)' do
      installation = create_credential(name: 'ElevenLabs da casa', scope: 'installation', provider: 'elevenlabs')

      expect(described_class.resolve_default(provider: 'elevenlabs')).to eq(installation)
    end

    it 'prefers the account credential over the installation one (AC5)' do
      create_credential(name: 'Da casa', scope: 'installation')
      account = create_credential(name: 'Da conta', scope: 'account')

      expect(described_class.resolve_default(provider: 'dify')).to eq(account)
    end

    it 'skips an inactive account credential and uses the installation one' do
      installation = create_credential(name: 'Da casa', scope: 'installation')
      create_credential(name: 'Da conta', scope: 'account', active: false)

      expect(described_class.resolve_default(provider: 'dify')).to eq(installation)
    end

    it 'only considers credentials of the requested provider' do
      create_credential(name: 'Dify da conta', provider: 'dify')
      n8n = create_credential(name: 'N8N da casa', scope: 'installation', provider: 'n8n')

      expect(described_class.resolve_default(provider: 'n8n')).to eq(n8n)
    end

    it 'returns nothing when no link offers a credential (AC6)' do
      expect(described_class.resolve_default(provider: 'dify')).to be_nil
    end

    it 'returns nothing for a blank provider rather than matching anything' do
      create_credential(name: 'Qualquer', scope: 'installation')

      expect(described_class.resolve_default(provider: nil)).to be_nil
    end

    # `account:` is threaded rather than queried, exactly as story 1.2 decided:
    # the community CRM is single-tenant, and the parameter exists so the
    # enterprise overlay can scope a link without rewriting this class.
    it 'accepts an account argument without changing community behaviour' do
      installation = create_credential(name: 'Da casa', scope: 'installation')

      expect(described_class.resolve_default(provider: 'dify', account: 42)).to eq(installation)
    end
  end

  describe 'oauth credentials are references, never values (AC7)' do
    it 'never decrypts an oauth credential' do
      create_credential(name: 'GitHub', provider: 'github', kind: 'oauth', scope: 'installation')

      expect(Ai::CredentialDecryptor).not_to receive(:decrypt)

      described_class.resolve_value(provider: 'github')
    end

    it 'reports an oauth credential as a reference instead of a value' do
      credential = create_credential(name: 'GitHub', provider: 'github', kind: 'oauth', scope: 'installation')

      result = described_class.resolve_value(provider: 'github')

      expect(result).to be_reference
      expect(result).not_to be_missing
      expect(result.credential).to eq(credential)
      expect(result.value).to be_nil
      expect(result.owner_store).to eq('agent_integration')
    end

    # AC6 and AC7 are different states. Collapsing both into a bare nil would
    # leave the caller unable to tell "nothing is configured" from "your
    # credential lives in another store, go read it there".
    it 'distinguishes a missing credential from an oauth reference' do
      missing = described_class.resolve_value(provider: 'dify')

      expect(missing).to be_missing
      expect(missing).not_to be_reference
      expect(missing.value).to be_nil
    end

    it 'still resolves the oauth row as a record' do
      credential = create_credential(name: 'GitHub', provider: 'github', kind: 'oauth', scope: 'installation')

      expect(described_class.resolve_default(provider: 'github')).to eq(credential)
    end
  end

  describe 'decryption of static credentials' do
    it 'returns the plaintext for the resolved credential' do
      create_credential(name: 'Dify', value: 'ciphertext-dify')
      allow(Ai::CredentialDecryptor).to receive(:decrypt).with('ciphertext-dify').and_return('app-dify-9c1d')

      result = described_class.resolve_value(provider: 'dify')

      expect(result).to be_present_value
      expect(result.value).to eq('app-dify-9c1d')
      expect(result.credential.name).to eq('Dify')
    end

    it 'resolves a value by reference too' do
      credential = create_credential(name: 'Dify', value: 'ciphertext-dify')
      allow(Ai::CredentialDecryptor).to receive(:decrypt).with('ciphertext-dify').and_return('app-dify-9c1d')

      expect(described_class.resolve_value(credential_id: credential.id).value).to eq('app-dify-9c1d')
    end

    it 'reports an undecryptable credential as missing instead of raising' do
      create_credential(name: 'Dify', value: 'lixo')
      allow(Ai::CredentialDecryptor).to receive(:decrypt).and_return(nil)

      result = described_class.resolve_value(provider: 'dify')

      expect(result).to be_missing
      expect(result.value).to be_nil
    end

    it 'reports missing when the reference cannot be honoured' do
      expect(described_class.resolve_value(credential_id: SecureRandom.uuid)).to be_missing
    end
  end
end
