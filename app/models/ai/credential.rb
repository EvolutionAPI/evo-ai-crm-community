# frozen_string_literal: true

# Read-only view over `evo_core_api_keys`, the AI credential registry.
#
# evo-ai-core-service owns the table and every write; the CRM reads it directly
# because both share the `evo_community` database and the resolver runs inside
# jobs, where there is no user bearer to forward over HTTP. `readonly?` makes an
# accidental save raise rather than diverge from the schema's owner.
#
# Absent from `db/schema.rb` on purpose — Rails does not own this table.
# rubocop:disable Rails/ApplicationRecord -- ApplicationRecord adds write-path
# validations (validates_column_content_length) and event mixins that make no
# sense for a read-only view over a table another service owns.
class Ai::Credential < ActiveRecord::Base
  # rubocop:enable Rails/ApplicationRecord
  self.table_name = 'evo_core_api_keys'

  SCOPE_INSTALLATION = 'installation'
  SCOPE_ACCOUNT = 'account'

  # Providers speaking the OpenAI wire protocol; the others only serve AI Agents.
  # Mirrors IsOpenAICompatible in the core's api_key model.
  OPENAI_COMPATIBLE_PROVIDERS = %w[openai azure custom custom_openai_compatible].freeze

  scope :active, -> { where(is_active: true) }
  scope :for_scope, ->(scope) { where(scope: scope) }
  scope :openai_compatible, -> { where(provider: OPENAI_COMPATIBLE_PROVIDERS) }

  # The migration writes with `insert_all!`, which bypasses instantiation, so
  # this still catches every accidental `save`/`update` on a loaded record.
  def readonly?
    true
  end

  def openai_compatible?
    OPENAI_COMPATIBLE_PROVIDERS.include?(provider)
  end
end
