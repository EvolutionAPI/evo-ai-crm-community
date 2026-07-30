# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_api_keys_table')

# `evo_core_api_keys` is created by the Go migrations of evo-ai-core-service and
# is deliberately absent from `db/schema.rb` (Rails does not own it), so the test
# database has no such table. We create it here to exercise the resolver against
# the real column set instead of stubbing the model away.
RSpec.describe Ai::CredentialResolver do
  # rubocop:disable RSpec/BeforeAfterAll -- creating the table is DDL, which
  # cannot run inside the per-example transaction. Shared helper so every spec
  # agrees on the column set.
  before(:all) { EvoCoreApiKeysTable.create! }
  after(:all) { EvoCoreApiKeysTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  before { Ai::Credential.delete_all }

  def create_credential(name:, scope:, provider: 'openai', active: true)
    # insert_all! is the point: the model is read-only, so the core service is
    # simulated writing straight to its own table.
    Ai::Credential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: name,
        provider: provider,
        key: "ciphertext-#{name}",
        key_hint: '4f2a',
        scope: scope,
        is_active: active,
        created_at: Time.current,
        updated_at: Time.current
      }]
    )
    Ai::Credential.find_by(name: name)
  end

  describe 'the ordered chain (AC3)' do
    it 'declares scopes from the most generic to the most specific' do
      expect(described_class::SCOPE_CHAIN).to eq(%i[installation account])
    end

    # FR2 guard: the enterprise overlay adds an `agency` link between
    # installation and account. Inserting a link must change precedence WITHOUT
    # editing the resolver — if this spec ever needs a resolver change to pass,
    # the "if account else installation" shape has crept back in.
    #
    # The stub targets Ai::ScopeChain since story 2.2 moved the chain there to
    # share it with the integration credential resolver. Stubbing the alias on
    # this class instead would define a constant nothing reads any more, and
    # this guard would go green while testing nothing.
    it 'resolves a link inserted into the chain without any resolver change' do
      stub_const('Ai::ScopeChain::SCOPE_CHAIN', %i[installation agency account])
      create_credential(name: 'Da instalacao', scope: 'installation')
      agency = create_credential(name: 'Da agencia', scope: 'agency')

      expect(described_class.resolve(for_consumer: :ai_agents)).to eq(agency)
    end

    it 'keeps honouring the most specific link when the new one is empty' do
      stub_const('Ai::ScopeChain::SCOPE_CHAIN', %i[installation agency account])
      create_credential(name: 'Da instalacao', scope: 'installation')
      account = create_credential(name: 'Da conta', scope: 'account')

      expect(described_class.resolve(for_consumer: :ai_agents)).to eq(account)
    end
  end

  describe 'precedence (AC4, AC5, AC6, AC7)' do
    it 'falls back to the installation credential when the account has none (AC4)' do
      installation = create_credential(name: 'Chave da casa', scope: 'installation')

      expect(described_class.resolve(for_consumer: :ai_agents)).to eq(installation)
    end

    it 'prefers the account credential over the installation one (AC5)' do
      create_credential(name: 'Chave da casa', scope: 'installation')
      account = create_credential(name: 'Producao', scope: 'account')

      expect(described_class.resolve(for_consumer: :ai_agents)).to eq(account)
    end

    it 'ignores an inactive account credential and inherits the default (AC6)' do
      installation = create_credential(name: 'Chave da casa', scope: 'installation')
      create_credential(name: 'Desativada', scope: 'account', active: false)

      expect(described_class.resolve(for_consumer: :ai_agents)).to eq(installation)
    end

    it 'returns nil, without raising, when no link has a credential (AC7)' do
      expect { described_class.resolve(for_consumer: :ai_agents) }.not_to raise_error
      expect(described_class.resolve(for_consumer: :ai_agents)).to be_nil
    end

    it 'returns nil when every credential is inactive (AC7)' do
      create_credential(name: 'Desativada', scope: 'account', active: false)
      create_credential(name: 'Tambem desativada', scope: 'installation', active: false)

      expect(described_class.resolve(for_consumer: :ai_agents)).to be_nil
    end
  end

  describe 'provider compatibility per consumer (AC8)' do
    it 'skips an incompatible account credential and inherits the default' do
      installation = create_credential(name: 'Chave da casa', scope: 'installation', provider: 'openai')
      create_credential(name: 'Claude Prod', scope: 'account', provider: 'anthropic')

      # The assist speaks the OpenAI protocol, so Anthropic is not "wrong
      # config" — it is a different wire format, and it must be skipped.
      expect(described_class.resolve(for_consumer: :inbox_assist)).to eq(installation)
    end

    it 'still serves the same credential to a consumer that accepts it' do
      anthropic = create_credential(name: 'Claude Prod', scope: 'account', provider: 'anthropic')

      expect(described_class.resolve(for_consumer: :ai_agents)).to eq(anthropic)
    end

    it 'returns nil when no link offers a compatible provider' do
      create_credential(name: 'Claude Prod', scope: 'account', provider: 'anthropic')
      create_credential(name: 'Gemini casa', scope: 'installation', provider: 'gemini')

      expect(described_class.resolve(for_consumer: :inbox_assist)).to be_nil
    end

    it 'resolves independently per consumer from the same registry' do
      create_credential(name: 'Chave da casa', scope: 'installation', provider: 'openai')
      anthropic = create_credential(name: 'Claude Prod', scope: 'account', provider: 'anthropic')

      expect(described_class.resolve(for_consumer: :ai_agents)).to eq(anthropic)
      expect(described_class.resolve(for_consumer: :inbox_assist).name).to eq('Chave da casa')
    end

    it 'returns nil for an unknown consumer instead of guessing' do
      create_credential(name: 'Producao', scope: 'account')

      expect(described_class.resolve(for_consumer: :not_a_consumer)).to be_nil
    end
  end

  describe 'the credential model' do
    it 'is read-only — writes belong to the core service' do
      credential = create_credential(name: 'Producao', scope: 'account')

      expect(credential.readonly?).to be(true)
      expect { credential.update!(name: 'Outro') }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end
end
