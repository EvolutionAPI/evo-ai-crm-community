# frozen_string_literal: true

# Read-only signals about the AI credential registry that the settings screen
# cannot derive from the credential list itself. Booleans only — never a key.
class Api::V1::Ai::CredentialsController < Api::V1::BaseController
  require_permissions({ migration_state: 'ai_api_keys.read' })

  # Whether the resolver still serves the legacy sources (global OPENAI_API_SECRET
  # / openai hook). The "in use" panel used to guess this from "no active
  # credential", which reads as "AI still runs" on a migrated install where it
  # is simply off.
  def migration_state
    migrated = Ai::MigrationState.migrated?

    success_response(data: { migrated: migrated, legacy_fallback_active: !migrated })
  end
end
