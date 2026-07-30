# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_integration_credentials_table')

RSpec.describe Ai::IntegrationCredentialMigration do
  # rubocop:disable RSpec/BeforeAfterAll -- DDL cannot run inside the per-example transaction.
  before(:all) { EvoCoreIntegrationCredentialsTable.create! }
  after(:all) { EvoCoreIntegrationCredentialsTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  before do
    Ai::IntegrationCredential.delete_all
    AgentBot.delete_all
    allow(Ai::CredentialDecryptor).to receive(:encryption_key).and_return(fernet_key)
  end

  # A real Fernet key, so the round-trip proof exercises the actual crypto
  # rather than a stub: the gate is only meaningful if what it writes is
  # readable back.
  let(:fernet_key) { 'cw_0x689RpI-jtRR7oE8h_eQsKImvJapLeSbXpwF4e4=' }

  def create_bot(provider:, api_key: nil, name: "bot-#{SecureRandom.hex(3)}")
    AgentBot.create!(name: name, bot_provider: provider, api_key: api_key, outgoing_url: 'https://exemplo.test/hook')
  end

  def imported_credentials
    Ai::IntegrationCredential.where.not(imported_from: nil)
  end

  def decrypt(credential)
    Ai::CredentialDecryptor.decrypt(credential.value)
  end

  describe 'dry run (AC2)' do
    it 'writes nothing and still reports' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')

      rows = described_class.call(apply: false)

      expect(rows).not_to be_empty
      expect(Ai::IntegrationCredential.count).to eq(0)
    end

    it 'is the default mode' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')

      described_class.call

      expect(Ai::IntegrationCredential.count).to eq(0)
    end
  end

  describe 'importing a channel bot (AC1)' do
    it 'creates one encrypted credential and links the bot' do
      bot = create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')

      described_class.call(apply: true)

      credential = imported_credentials.first
      expect(credential).to be_present
      expect(credential.value).not_to eq('chave-do-bot-9c1d')
      expect(decrypt(credential)).to eq('chave-do-bot-9c1d')
      expect(credential.value_hint).to eq('9c1d')
      expect(bot.reload.credential_id).to eq(credential.id)
    end

    it 'does not delete the inline value: the fallback still needs it' do
      bot = create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')

      described_class.call(apply: true)

      expect(bot.reload.api_key).to eq('chave-do-bot-9c1d')
    end

    # The bot is the one consumer whose real runtime path lives in Ruby, so the
    # proof goes through it rather than through a round-trip.
    it 'keeps the effective key the resolver returns' do
      bot = create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')
      before_key = AgentBots::CredentialResolution.api_key_for(bot)

      described_class.call(apply: true)

      expect(AgentBots::CredentialResolution.api_key_for(bot.reload)).to eq(before_key)
    end
  end

  describe 'the n8n pair (AC5)' do
    it 'stores the pair structured and keeps the wire format identical' do
      bot = create_bot(provider: 'n8n_provider', api_key: 'admin:s3nha-f9b2')
      before_pair = AgentBots::CredentialResolution.basic_auth_for(bot)

      described_class.call(apply: true)

      credential = imported_credentials.first
      expect(credential.value_format).to eq('composite')
      expect(JSON.parse(decrypt(credential))).to eq('user' => 'admin', 'password' => 's3nha-f9b2')
      # The hint comes from the SECRET half, never from the envelope or the user.
      expect(credential.value_hint).to eq('f9b2')
      expect(AgentBots::CredentialResolution.basic_auth_for(bot.reload)).to eq(before_pair)
    end
  end

  describe 'deliberate skips (AC4)' do
    it 'skips a webhook bot, reporting it rather than failing' do
      create_bot(provider: 'webhook_provider')

      rows = described_class.call(apply: true)

      expect(imported_credentials.count).to eq(0)
      expect(rows.map(&:verdict)).to include('PULADO')
    end

    it 'skips a bot with no key at all' do
      create_bot(provider: 'n8n_provider', api_key: nil)

      described_class.call(apply: true)

      expect(imported_credentials.count).to eq(0)
    end
  end

  describe 'deduplication by value (AC6)' do
    it 'creates one credential for a secret shared by several consumers' do
      bots = Array.new(3) { create_bot(provider: 'evo_ai_provider', api_key: 'mesma-chave-1234') }

      described_class.call(apply: true)

      expect(imported_credentials.count).to eq(1)
      credential_id = imported_credentials.first.id
      expect(bots.map { |bot| bot.reload.credential_id }).to all(eq(credential_id))
    end

    it 'keeps distinct secrets apart' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-a-1111')
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-b-2222')

      described_class.call(apply: true)

      expect(imported_credentials.count).to eq(2)
    end
  end

  describe 'idempotency (AC3)' do
    it 'does not duplicate on a second run' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')

      described_class.call(apply: true)
      described_class.call(apply: true)

      expect(imported_credentials.count).to eq(1)
    end

    it 'does not duplicate a shared secret on a second run' do
      Array.new(3) { create_bot(provider: 'evo_ai_provider', api_key: 'mesma-chave-1234') }

      described_class.call(apply: true)
      described_class.call(apply: true)

      expect(imported_credentials.count).to eq(1)
    end

    it 'never reverts a human rename' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')
      described_class.call(apply: true)
      Ai::IntegrationCredential.where.not(imported_from: nil).update_all(name: 'Renomeada por humano') # rubocop:disable Rails/SkipsModelValidations

      described_class.call(apply: true)

      expect(imported_credentials.pluck(:name)).to eq(['Renomeada por humano'])
    end

    it 'never relinks a consumer a human pointed elsewhere' do
      bot = create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')
      described_class.call(apply: true)
      human_choice = SecureRandom.uuid
      AgentBot.where(id: bot.id).update_all(credential_id: human_choice) # rubocop:disable Rails/SkipsModelValidations

      described_class.call(apply: true)

      expect(bot.reload.credential_id).to eq(human_choice)
    end
  end

  describe 'empty installation (AC7)' do
    it 'finishes without writing and without error' do
      expect { described_class.call(apply: true) }.not_to raise_error
      expect(Ai::IntegrationCredential.count).to eq(0)
    end
  end

  describe 'deterministic naming (AC8)' do
    it 'suffixes a colliding name instead of violating the unique index' do
      Ai::IntegrationCredential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
        [{
          name: "#{described_class::BOT_NAME_PREFIX} evo_ai", provider: 'evo_ai', kind: 'static',
          value: 'x', value_format: 'scalar', value_hint: 'xxxx', scope: 'account',
          is_active: true, created_at: Time.current, updated_at: Time.current
        }]
      )
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')

      expect { described_class.call(apply: true) }.not_to raise_error
      expect(imported_credentials.first.name).to match(/\(\d+\)\z/)
    end
  end

  describe 'the report is a gate, not a log (AC2)' do
    it 'aborts apply when a consumer would change effective value' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')
      # Simulate the migration writing a value that does not round-trip.
      allow(Ai::CredentialDecryptor).to receive(:decrypt).and_return('valor-diferente')

      expect { described_class.call(apply: true) }.to raise_error(described_class::AbortedError, /DIVERGE|diverg/i)
      expect(Ai::IntegrationCredential.count).to eq(0)
    end

    it 'refuses to write when the encryption key is missing' do
      allow(Ai::CredentialDecryptor).to receive(:encryption_key).and_return(nil)
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')

      expect { described_class.call(apply: true) }.to raise_error(described_class::AbortedError, /EVO_AI_ENCRYPTION_KEY/)
    end
  end

  describe 'oauth rows are never touched (AC9)' do
    it 'copies no token and creates no credential for an oauth row' do
      Ai::IntegrationCredential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
        [{
          name: 'GitHub conectado', provider: 'github', kind: 'oauth',
          value: nil, value_format: 'scalar', value_hint: '', scope: 'account',
          is_active: true, owner_store: 'agent_integration', owner_ref: SecureRandom.uuid,
          created_at: Time.current, updated_at: Time.current
        }]
      )

      described_class.call(apply: true)

      expect(imported_credentials.count).to eq(0)
      expect(Ai::IntegrationCredential.where(kind: 'oauth').first.value).to be_nil
    end
  end

  # The digest in `imported_from` proves the secret was imported once, not that
  # the row still holds it. Linking a new consumer to a rotated credential would
  # swap the secret on the wire with no DIVERGE anywhere — the exact silent
  # change the gate forbids.
  describe 'dedupe against a humanly rotated credential' do
    it 'aborts instead of linking a new consumer to a value that no longer matches' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-compartilhada-9c1d')
      described_class.call(apply: true)

      # A human rotates the imported credential's value afterwards.
      Ai::IntegrationCredential.where.not(imported_from: nil).update_all( # rubocop:disable Rails/SkipsModelValidations
        value: Ai::CredentialEncryptor.encrypt('valor-rotacionado-f00d')
      )

      # A NEW consumer still carrying the OLD secret shows up on a later run.
      late_bot = create_bot(provider: 'evo_ai_provider', api_key: 'chave-compartilhada-9c1d')

      expect { described_class.call(apply: true) }
        .to raise_error(described_class::AbortedError, /alterada depois da importação/)
      expect(late_bot.reload.credential_id).to be_nil
    end

    it 'still links a new consumer when the imported value is untouched (idempotent path)' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-compartilhada-9c1d')
      described_class.call(apply: true)

      late_bot = create_bot(provider: 'evo_ai_provider', api_key: 'chave-compartilhada-9c1d')
      described_class.call(apply: true)

      expect(imported_credentials.count).to eq(1)
      expect(late_bot.reload.credential_id).to eq(imported_credentials.first.id)
    end
  end

  describe Ai::IntegrationMigrationState do
    it 'reports not migrated while a secret still lives only in the old store' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')

      expect(described_class.migrated?).to be(false)
    end

    it 'reports migrated once the task has run' do
      create_bot(provider: 'evo_ai_provider', api_key: 'chave-do-bot-9c1d')
      Ai::IntegrationCredentialMigration.call(apply: true)

      expect(described_class.migrated?).to be(true)
    end

    it 'reports migrated on an installation that has nothing to migrate' do
      expect(described_class.migrated?).to be(true)
    end
  end
end
