# frozen_string_literal: true

# Read-only view over `evo_core_integration_credentials`, the integration
# credential vault. Same arrangement as Ai::Credential: the core owns the table
# and every write, and the CRM reads it directly because the resolver runs in
# jobs, with no user bearer to forward over HTTP.
class Ai::IntegrationCredential < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord -- write-path validations make no sense on a read-only view of a foreign table
  self.table_name = 'evo_core_integration_credentials'

  KIND_STATIC = 'static'
  KIND_OAUTH = 'oauth'

  # Mirrors the scope chain of Ai::Credential: this service stores the scope, and
  # Ai::IntegrationCredentialResolver owns the precedence between links.
  SCOPE_INSTALLATION = 'installation'
  SCOPE_ACCOUNT = 'account'

  VALUE_FORMAT_SCALAR = 'scalar'
  VALUE_FORMAT_COMPOSITE = 'composite'

  scope :active, -> { where(is_active: true) }
  scope :for_scope, ->(scope) { where(scope: scope) }
  scope :for_provider, ->(provider) { where(provider: provider) }
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
