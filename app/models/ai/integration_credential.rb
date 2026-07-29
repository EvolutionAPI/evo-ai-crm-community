# frozen_string_literal: true

# Read-only view over `evo_core_integration_credentials`, the integration
# credential vault (EVO-2250, epic 2).
#
# Same arrangement as Ai::Credential over `evo_core_api_keys`: the table belongs
# to evo-ai-core-service (Go), which owns its migrations and every write, and
# both services share the `evo_community` database, so the CRM reads it directly
# — the resolver runs inside background jobs where there is no user bearer to
# forward over HTTP.
#
# Not present in `db/schema.rb` on purpose — Rails does not own this table.
class Ai::IntegrationCredential < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- write-path validations make no sense on a read-only view of a foreign table
  self.table_name = 'evo_core_integration_credentials'

  KIND_STATIC = 'static'
  KIND_OAUTH = 'oauth'

  VALUE_FORMAT_SCALAR = 'scalar'
  VALUE_FORMAT_COMPOSITE = 'composite'

  scope :active, -> { where(is_active: true) }
  scope :for_scope, ->(scope) { where(scope: scope) }
  scope :static_kind, -> { where(kind: KIND_STATIC) }
  scope :oauth_kind, -> { where(kind: KIND_OAUTH) }

  def readonly?
    true
  end

  def static?
    kind == KIND_STATIC
  end

  def oauth?
    kind == KIND_OAUTH
  end
end
