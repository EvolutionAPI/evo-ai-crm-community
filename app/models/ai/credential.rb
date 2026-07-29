# frozen_string_literal: true

# Read-only view over `evo_core_api_keys`, the AI credential registry.
#
# The table belongs to evo-ai-core-service (Go), which owns its migrations and
# every write. Both services share the same `evo_community` database, so the CRM
# reads it directly instead of going over HTTP — the resolver runs inside
# background jobs (audio transcription, moderation) where there is no logged-in
# user whose bearer could be forwarded to the core.
#
# Writes stay in the core: `readonly?` makes an accidental save raise instead of
# silently diverging from the owner of the schema.
#
# Not present in `db/schema.rb` on purpose — Rails does not own this table.
# rubocop:disable Rails/ApplicationRecord -- ApplicationRecord adds write-path
# validations (validates_column_content_length) and event mixins that make no
# sense for a read-only view over a table another service owns.
class Ai::Credential < ActiveRecord::Base
  # rubocop:enable Rails/ApplicationRecord
  self.table_name = 'evo_core_api_keys'

  SCOPE_INSTALLATION = 'installation'
  SCOPE_ACCOUNT = 'account'

  # Mirrors IsOpenAICompatible in
  # evo-ai-core-service-community/pkg/api_key/model/api_key.go — providers
  # speaking the OpenAI wire protocol. The others only serve AI Agents.
  OPENAI_COMPATIBLE_PROVIDERS = %w[openai azure custom custom_openai_compatible].freeze

  scope :active, -> { where(is_active: true) }
  scope :for_scope, ->(scope) { where(scope: scope) }
  scope :openai_compatible, -> { where(provider: OPENAI_COMPATIBLE_PROVIDERS) }

  # Writes belong to evo-ai-core-service. The one exception is the 1.5 migration,
  # which uses `insert_all!` — that bypasses instantiation, so this guard still
  # catches every accidental `save`/`update` through a loaded record.
  def readonly?
    true
  end

  def openai_compatible?
    OPENAI_COMPATIBLE_PROVIDERS.include?(provider)
  end
end
