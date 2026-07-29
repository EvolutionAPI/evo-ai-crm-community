# frozen_string_literal: true

# Read-only view over `evo_core_agent_integrations` (EVO-2250, story 2.6).
#
# ⚠️ The table holds TWO different things: the static platform credentials of
# external agents and native tools (dify, flowise, n8n, elevenlabs,
# knowledge_nexus) AND the OAuth connection rows plus their `<provider>_credentials`
# satellites. Only the first group belongs in the vault, so every reader here
# filters by an explicit provider allowlist.
class Ai::AgentIntegration < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- write-path validations make no sense on a read-only view of a foreign table
  self.table_name = 'evo_core_agent_integrations'

  # Providers whose config carries a STATIC secret the customer registered.
  # Mirrors the negative of IsConnectionProvider in the Go side (story 2.5):
  # OAuth connections and their satellite rows are never imported.
  STATIC_PROVIDERS = %w[dify flowise n8n openai elevenlabs knowledge_nexus].freeze

  scope :static_providers, -> { where(provider: STATIC_PROVIDERS) }

  def readonly?
    true
  end
end
