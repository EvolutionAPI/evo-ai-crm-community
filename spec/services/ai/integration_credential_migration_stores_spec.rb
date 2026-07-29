# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_integration_credentials_table')
require Rails.root.join('spec/support/evo_core_custom_tools_table')
require Rails.root.join('spec/support/evo_core_custom_mcp_servers_table')
require Rails.root.join('spec/support/evo_core_agent_integrations_table')

# EVO-2250 story 2.6, the stores beyond the channel bot.
RSpec.describe Ai::IntegrationCredentialMigration do
  # rubocop:disable RSpec/BeforeAfterAll -- DDL cannot run inside the per-example transaction.
  before(:all) do
    EvoCoreIntegrationCredentialsTable.create!
    EvoCoreCustomToolsTable.create!
    EvoCoreCustomMcpServersTable.create!
    EvoCoreAgentIntegrationsTable.create!
  end

  after(:all) do
    EvoCoreAgentIntegrationsTable.drop!
    EvoCoreCustomMcpServersTable.drop!
    EvoCoreCustomToolsTable.drop!
    EvoCoreIntegrationCredentialsTable.drop!
  end
  # rubocop:enable RSpec/BeforeAfterAll

  before do
    Ai::IntegrationCredential.delete_all
    Ai::CustomTool.delete_all
    Ai::CustomMcpServer.delete_all
    Ai::AgentIntegration.delete_all
    AgentBot.delete_all
    allow(Ai::CredentialDecryptor).to receive(:encryption_key).and_return(fernet_key)
  end

  let(:fernet_key) { 'cw_0x689RpI-jtRR7oE8h_eQsKImvJapLeSbXpwF4e4=' }

  def create_tool(headers:, name: "tool-#{SecureRandom.hex(3)}")
    Ai::CustomTool.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: name, method: 'POST', endpoint: 'https://exemplo.test/api',
        headers: headers.to_json, credential_refs: {},
        path_params: '{}', query_params: '{}', body_params: '{}',
        error_handling: '{}', values: '{}', is_active: true,
        created_at: Time.current, updated_at: Time.current
      }]
    )
    Ai::CustomTool.find_by(name: name)
  end

  def create_mcp(headers:, name: "mcp-#{SecureRandom.hex(3)}")
    Ai::CustomMcpServer.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: name, url: 'https://mcp.exemplo.test', headers: headers.to_json,
        credential_refs: {}, timeout: 30, retry_count: 0, is_active: true,
        created_at: Time.current, updated_at: Time.current
      }]
    )
    Ai::CustomMcpServer.find_by(name: name)
  end

  def create_integration(provider:, config:, agent_id: SecureRandom.uuid)
    Ai::AgentIntegration.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        agent_id: agent_id, provider: provider, config: config,
        created_at: Time.current, updated_at: Time.current
      }]
    )
    Ai::AgentIntegration.find_by(agent_id: agent_id, provider: provider)
  end

  def imported
    Ai::IntegrationCredential.where.not(imported_from: nil)
  end

  def decrypt(credential)
    Ai::CredentialDecryptor.decrypt(credential.value)
  end

  describe 'custom tools' do
    it 'imports a recognised auth header and links it by name' do
      tool = create_tool(headers: { 'Authorization' => 'Bearer sk-secreto-9c1d', 'Content-Type' => 'application/json' })

      described_class.call(apply: true)

      credential = imported.first
      expect(decrypt(credential)).to eq('Bearer sk-secreto-9c1d')
      expect(tool.reload.credential_refs).to eq('Authorization' => credential.id)
    end

    it 'imports two auth headers as two distinct credentials (cardinality rule)' do
      tool = create_tool(headers: { 'Authorization' => 'Bearer um-1111', 'X-Api-Key' => 'dois-2222' })

      described_class.call(apply: true)

      expect(imported.count).to eq(2)
      expect(tool.reload.credential_refs.keys).to contain_exactly('Authorization', 'X-Api-Key')
      expect(tool.credential_refs.values.uniq.size).to eq(2)
    end

    # The heuristic must err on the side of NOT migrating: importing a header
    # that is not a secret breaks the call, while leaving one behind only delays
    # the gain. The two mistakes do not cost the same.
    it 'leaves headers that are not recognised auth headers alone' do
      tool = create_tool(headers: { 'Content-Type' => 'application/json', 'X-Trace-Id' => 'abc' })

      described_class.call(apply: true)

      expect(imported.count).to eq(0)
      expect(tool.reload.credential_refs).to eq({})
    end

    it 'does not delete the inline header: the fallback still needs it' do
      tool = create_tool(headers: { 'Authorization' => 'Bearer sk-secreto-9c1d' })

      described_class.call(apply: true)

      expect(JSON.parse(tool.reload.headers)).to include('Authorization' => 'Bearer sk-secreto-9c1d')
    end
  end

  describe 'custom MCP servers' do
    it 'imports the auth header and links it' do
      mcp = create_mcp(headers: { 'Authorization' => 'Bearer mcp-7a3c' })

      described_class.call(apply: true)

      credential = imported.first
      expect(decrypt(credential)).to eq('Bearer mcp-7a3c')
      expect(mcp.reload.credential_refs).to eq('Authorization' => credential.id)
    end
  end

  describe 'agent integrations (static providers only)' do
    it 'imports the dify apiKey' do
      integration = create_integration(provider: 'dify', config: { 'apiUrl' => 'https://dify.test', 'apiKey' => 'app-dify-9c1d' })

      described_class.call(apply: true)

      credential = imported.first
      expect(decrypt(credential)).to eq('app-dify-9c1d')
      expect(integration.reload.config['credential_id']).to eq(credential.id)
    end

    it 'imports the knowledge nexus key and leaves the address fields alone' do
      integration = create_integration(
        provider: 'knowledge_nexus',
        config: { 'nexus_base_url' => 'https://nexus.test', 'nexus_api_key' => 'evo_k_ab.cd9c1d', 'space_id' => 'sp-1' }
      )

      described_class.call(apply: true)

      expect(decrypt(imported.first)).to eq('evo_k_ab.cd9c1d')
      config = integration.reload.config
      expect(config['nexus_base_url']).to eq('https://nexus.test')
      expect(config['space_id']).to eq('sp-1')
    end

    it 'imports the n8n pair as a composite envelope' do
      create_integration(provider: 'n8n', config: { 'webhookUrl' => 'https://n8n.test', 'basicAuthUser' => 'admin', 'basicAuthPass' => 's3nha-f9b2' })

      described_class.call(apply: true)

      credential = imported.first
      expect(credential.value_format).to eq('composite')
      expect(JSON.parse(decrypt(credential))).to eq('user' => 'admin', 'password' => 's3nha-f9b2')
      expect(credential.value_hint).to eq('f9b2')
    end

    # ⚠️ The correction from the adversarial review: this key is GENERATED by the
    # core (it is the agent's inbound key), never registered by the customer. It
    # is a deliberate skip, not a credential to import.
    it 'skips an OAuth connection row entirely (AC9)' do
      create_integration(provider: 'github', config: { 'access_token' => 'gho_secreto', 'connected' => true })

      rows = described_class.call(apply: true)

      expect(imported.count).to eq(0)
      expect(rows.select(&:skipped?)).not_to be_empty
    end

    it 'skips a satellite credentials row' do
      create_integration(provider: 'google_calendar_credentials', config: { 'access_token' => 'ya29', 'refresh_token' => 'r' })

      described_class.call(apply: true)

      expect(imported.count).to eq(0)
    end

    it 'skips typebot, which authenticates with nothing' do
      create_integration(provider: 'typebot', config: { 'url' => 'https://typebot.test', 'typebot' => 'fluxo' })

      described_class.call(apply: true)

      expect(imported.count).to eq(0)
    end
  end

  describe 'deduplication across stores (AC6)' do
    it 'creates one credential when a tool and an MCP share the same secret' do
      tool = create_tool(headers: { 'Authorization' => 'Bearer compartilhado-1234' })
      mcp = create_mcp(headers: { 'Authorization' => 'Bearer compartilhado-1234' })

      described_class.call(apply: true)

      expect(imported.count).to eq(1)
      credential_id = imported.first.id
      expect(tool.reload.credential_refs['Authorization']).to eq(credential_id)
      expect(mcp.reload.credential_refs['Authorization']).to eq(credential_id)
    end
  end

  describe 'idempotency across stores (AC3)' do
    it 'does not duplicate nor relink on a second run' do
      tool = create_tool(headers: { 'Authorization' => 'Bearer sk-secreto-9c1d' })
      create_integration(provider: 'dify', config: { 'apiKey' => 'app-dify-9c1d' })

      described_class.call(apply: true)
      first_refs = tool.reload.credential_refs
      described_class.call(apply: true)

      expect(imported.count).to eq(2)
      expect(tool.reload.credential_refs).to eq(first_refs)
    end

    it 'never overwrites a reference a human changed' do
      tool = create_tool(headers: { 'Authorization' => 'Bearer sk-secreto-9c1d' })
      described_class.call(apply: true)
      human_choice = SecureRandom.uuid
      Ai::CustomTool.where(id: tool.id).update_all(credential_refs: { 'Authorization' => human_choice }) # rubocop:disable Rails/SkipsModelValidations

      described_class.call(apply: true)

      expect(tool.reload.credential_refs).to eq('Authorization' => human_choice)
    end
  end

  describe 'the gate covers every store (AC2)' do
    it 'aborts without writing when a value would not round-trip' do
      create_tool(headers: { 'Authorization' => 'Bearer sk-secreto-9c1d' })
      allow(Ai::CredentialDecryptor).to receive(:decrypt).and_return('valor-diferente')

      expect { described_class.call(apply: true) }.to raise_error(described_class::AbortedError)
      expect(Ai::IntegrationCredential.count).to eq(0)
    end
  end
end
