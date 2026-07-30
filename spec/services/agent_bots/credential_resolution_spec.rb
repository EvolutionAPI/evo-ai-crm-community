# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_integration_credentials_table')

# EVO-2250 story 2.4.
#
# A channel bot may point at the integration credential vault instead of holding
# its key inline. The inline `api_key` stays the fallback until story 2.7, so no
# installation has to migrate for this to ship.
RSpec.describe AgentBots::CredentialResolution do
  # rubocop:disable RSpec/BeforeAfterAll -- DDL cannot run inside the per-example transaction.
  before(:all) { EvoCoreIntegrationCredentialsTable.create! }
  after(:all) { EvoCoreIntegrationCredentialsTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  before do
    Ai::IntegrationCredential.delete_all
    # These examples exercise PRECEDENCE (vault vs inline), with the bot built in
    # memory. The retirement gate is a separate axis, covered by
    # spec/services/agent_bots/retirement_path_spec.rb: here the installation is
    # declared NOT migrated so the inline fallback is reachable and the
    # precedence assertions stay meaningful.
    allow(Ai::IntegrationMigrationState).to receive(:migrated?).and_return(false)
  end

  def create_credential(value:, kind: 'static', value_format: 'scalar', active: true)
    Ai::IntegrationCredential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: "cred-#{SecureRandom.hex(4)}",
        provider: 'evo_ai',
        kind: kind,
        value: value,
        value_format: value_format,
        value_hint: 'abcd',
        scope: 'account',
        is_active: active,
        owner_store: kind == 'oauth' ? 'agent_integration' : nil,
        owner_ref: kind == 'oauth' ? SecureRandom.uuid : nil,
        created_at: Time.current,
        updated_at: Time.current
      }]
    )
    Ai::IntegrationCredential.order(created_at: :desc).first
  end

  def bot(credential_id: nil, api_key: nil)
    instance_double(AgentBot, credential_id: credential_id, api_key: api_key)
  end

  describe '.api_key_for' do
    it 'returns the vault value when the bot references a credential' do
      credential = create_credential(value: 'ciphertext')
      allow(Ai::CredentialDecryptor).to receive(:decrypt).with('ciphertext').and_return('chave-do-cofre')

      expect(described_class.api_key_for(bot(credential_id: credential.id))).to eq('chave-do-cofre')
    end

    it 'falls back to the inline key when there is no reference (AC2)' do
      expect(Ai::CredentialDecryptor).not_to receive(:decrypt)

      expect(described_class.api_key_for(bot(api_key: 'chave-inline'))).to eq('chave-inline')
    end

    it 'falls back to the inline key when the reference cannot be resolved (AC9)' do
      expect(described_class.api_key_for(bot(credential_id: SecureRandom.uuid, api_key: 'chave-inline')))
        .to eq('chave-inline')
    end

    it 'falls back when the referenced credential is inactive' do
      credential = create_credential(value: 'ciphertext', active: false)

      expect(described_class.api_key_for(bot(credential_id: credential.id, api_key: 'chave-inline')))
        .to eq('chave-inline')
    end

    # An oauth credential holds no value: the vault points at the store that owns
    # the token instead of copying it.
    it 'falls back when the referenced credential is oauth' do
      credential = create_credential(value: nil, kind: 'oauth')

      expect(described_class.api_key_for(bot(credential_id: credential.id, api_key: 'chave-inline')))
        .to eq('chave-inline')
    end

    it 'returns nil when neither the reference nor an inline key resolves' do
      expect(described_class.api_key_for(bot(credential_id: SecureRandom.uuid))).to be_nil
    end

    it 'never falls through to another credential of the same provider' do
      other = create_credential(value: 'ciphertext-de-outro')
      allow(Ai::CredentialDecryptor).to receive(:decrypt).and_return('chave-de-outro')

      # A reference that does not resolve must not silently pick a different
      # credential: the bot was configured with one specific secret.
      expect(described_class.api_key_for(bot(credential_id: SecureRandom.uuid))).to be_nil
      expect(other).to be_present
    end
  end

  describe '.basic_auth_for (n8n)' do
    # The stored shape changed, the wire format did not: what has to stay
    # identical is the byte that goes out in the Authorization header.
    it 'builds the same pair a colon-separated inline key builds today' do
      credential = create_credential(value: 'ciphertext', value_format: 'composite')
      allow(Ai::CredentialDecryptor).to receive(:decrypt)
        .with('ciphertext').and_return('{"user":"admin","password":"s3nha"}')

      from_vault = described_class.basic_auth_for(bot(credential_id: credential.id))
      from_inline = described_class.basic_auth_for(bot(api_key: 'admin:s3nha'))

      expect(from_vault).to eq(%w[admin s3nha])
      expect(from_vault).to eq(from_inline)
    end

    it 'keeps the inline colon split when there is no reference' do
      expect(described_class.basic_auth_for(bot(api_key: 'admin:s3nha'))).to eq(%w[admin s3nha])
    end

    it 'returns nil when the inline key has no colon (it is an api key, not basic auth)' do
      expect(described_class.basic_auth_for(bot(api_key: 'chave-sem-dois-pontos'))).to be_nil
    end

    it 'returns nil for a composite envelope that has no usable pair' do
      credential = create_credential(value: 'ciphertext', value_format: 'composite')
      allow(Ai::CredentialDecryptor).to receive(:decrypt).with('ciphertext').and_return('nao-e-json')

      expect(described_class.basic_auth_for(bot(credential_id: credential.id))).to be_nil
    end

    # MÉDIO 12 of the review: `JSON.parse("12345")` returns an Integer, so
    # `envelope['user']` raised TypeError OUTSIDE the JSON::ParserError rescue and
    # took the n8n bot request down. A scalar secret is not an envelope — it is
    # exactly what the colon convention handles.
    it 'treats a scalar vault value as an inline key instead of raising' do
      credential = create_credential(value: 'ciphertext', value_format: 'composite')

      ['12345', 'true', 'null', '"apenas-texto"'].each do |scalar|
        allow(Ai::CredentialDecryptor).to receive(:decrypt).with('ciphertext').and_return(scalar)

        expect { described_class.basic_auth_for(bot(credential_id: credential.id)) }
          .not_to raise_error, "a scalar vault value (#{scalar}) crashed the bot request"
      end
    end

    it 'still splits a scalar that carries the pair in the colon convention' do
      credential = create_credential(value: 'ciphertext', value_format: 'composite')
      allow(Ai::CredentialDecryptor).to receive(:decrypt).with('ciphertext').and_return('admin:s3nha')

      expect(described_class.basic_auth_for(bot(credential_id: credential.id))).to eq(%w[admin s3nha])
    end
  end
end
