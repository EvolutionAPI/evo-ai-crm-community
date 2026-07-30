# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_integration_credentials_table')

# EVO-2250, review of 2026-07-29 (blocker 3 + finding 10).
#
# The 2.7 retirement was cosmetic: the UI hid the field while the runtime kept
# reading `agent_bots.api_key` unconditionally, and `Ai::IntegrationMigrationState`
# — the guard ACs 3 and 4 require — had ZERO production callers.
#
# These are PATH tests: they go through `AgentBots::CredentialResolution`, the
# function the six consumption points actually call, and assert on what comes out
# for each guard state. A test over the guard alone is what let this ship.
# rubocop:disable RSpec/DescribeClass -- this covers a PATH across the guard and the resolver, not one class
RSpec.describe 'Agent bot inline retirement path' do
  # rubocop:disable RSpec/BeforeAfterAll -- DDL cannot run inside the per-example transaction.
  before(:all) do
    EvoCoreIntegrationCredentialsTable.create!
    require Rails.root.join('spec/support/evo_core_agent_integrations_table')
    EvoCoreAgentIntegrationsTable.create!
  end

  # Dropped, not just emptied: leaving the table behind changed what
  # Ai::IntegrationMigrationState saw in OTHER spec files, which is a test-order
  # dependency and not a real defect of the guard.
  after(:all) do
    EvoCoreAgentIntegrationsTable.drop!
    EvoCoreIntegrationCredentialsTable.drop!
  end
  # rubocop:enable RSpec/BeforeAfterAll

  before do
    Ai::IntegrationCredential.delete_all
    AgentBot.delete_all
  end

  let(:bot) do
    AgentBot.create!(name: "bot-#{SecureRandom.hex(3)}", bot_provider: 'evo_ai_provider',
                     api_key: 'chave-inline', outgoing_url: 'https://exemplo.test/hook')
  end

  describe 'while the installation has NOT migrated' do
    it 'still uses the inline key, so nothing goes dark before the migration runs' do
      bot # the bot must exist before the guard is asked: it IS the legacy source
      expect(Ai::IntegrationMigrationState.migrated?).to be(false)

      expect(AgentBots::CredentialResolution.api_key_for(bot)).to eq('chave-inline')
    end
  end

  describe 'once the installation HAS migrated' do
    before do
      # The 2.6 task ran: a credential carries `imported_from`.
      Ai::IntegrationCredential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
        [{
          name: 'Migrada', provider: 'evo_ai', kind: 'static', value: 'cipher',
          value_format: 'scalar', value_hint: 'abcd', scope: 'account', is_active: true,
          imported_from: 'integration:sha256:abc', created_at: Time.current, updated_at: Time.current
        }]
      )
    end

    # The whole point of AC2: the inline value stops being read.
    it 'ignores the inline key even though the column still holds it' do
      expect(Ai::IntegrationMigrationState.migrated?).to be(true)

      expect(AgentBots::CredentialResolution.api_key_for(bot)).to be_nil
    end

    it 'uses the vault credential the bot references' do
      credential = Ai::IntegrationCredential.first
      AgentBot.where(id: bot.id).update_all(credential_id: credential.id) # rubocop:disable Rails/SkipsModelValidations
      allow(Ai::CredentialDecryptor).to receive(:decrypt).with('cipher').and_return('chave-do-cofre')

      expect(AgentBots::CredentialResolution.api_key_for(bot.reload)).to eq('chave-do-cofre')
    end
  end

  # Finding 10: the guard only inspected AgentBot, so an installation whose
  # inline secret lives in a Dify integration and has no bots answered
  # "migrated" — and retiring the inline read there is a fail-open that leaves
  # the agent authenticating with nothing.
  describe 'the guard sees every store the 2.6 migration touches' do
    before { AgentBot.delete_all }

    it 'is not migrated while an agent integration still holds an inline secret' do
      Ai::AgentIntegration.delete_all
      Ai::AgentIntegration.insert_all!( # rubocop:disable Rails/SkipsModelValidations
        [{
          agent_id: SecureRandom.uuid, provider: 'dify',
          config: { 'apiKey' => 'app-dify-inline' },
          created_at: Time.current, updated_at: Time.current
        }]
      )

      expect(Ai::IntegrationMigrationState.migrated?).to be(false),
                                                         'an inline Dify secret was ignored: retiring here authenticates with nothing'
    ensure
      Ai::AgentIntegration.delete_all
    end
  end
end
# rubocop:enable RSpec/DescribeClass
