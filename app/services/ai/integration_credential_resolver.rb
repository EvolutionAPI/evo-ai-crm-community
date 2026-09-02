# frozen_string_literal: true

# Resolves which integration credential is in effect: the Dify key, the n8n
# basic auth, an MCP header, the Knowledge Nexus key. Precedence comes from the
# shared Ai::ScopeChain, never reimplemented here.
#
# The difference from the AI resolver: the normal case is a REFERENCE, because a
# Dify agent uses the key of that Dify and not "the default key". The chain
# still serves the narrower case of a per-provider scope default. Both live here
# so consumers never resolve an id by hand and spread the rule again.
class Ai::IntegrationCredentialResolver
  # Three outcomes callers must tell apart: missing, reference (an oauth
  # connection whose secret lives in the store that owns it) and value.
  #
  # Collapsing reference into missing would leave a consumer unable to tell
  # "you have no credential" from "your credential lives somewhere else".
  Resolution = Struct.new(:credential, :value, keyword_init: true) do
    def missing?
      credential.nil? || (credential.static? && value.blank?)
    end

    def reference?
      credential.present? && credential.oauth?
    end

    def present_value?
      credential.present? && credential.static? && value.present?
    end

    def owner_store
      credential&.owner_store
    end

    def owner_ref
      credential&.owner_ref
    end
  end

  class << self
    # Returns the referenced credential, or nil when the reference cannot be
    # honoured. It NEVER falls through to the chain: a consumer configured with
    # one credential must not silently authenticate with another.
    def resolve_by_id(credential_id)
      return nil if credential_id.blank?

      Ai::IntegrationCredential.active.find_by(id: credential_id)
    rescue ActiveRecord::StatementInvalid => e
      # A malformed uuid is a bad reference, not an outage.
      Rails.logger.error("Ai::IntegrationCredentialResolver: #{e.class}: #{e.message}")
      nil
    end

    # The default credential for a provider, walking the chain most specific
    # first. `account:` is threaded rather than queried: this CRM has no accounts
    # table, and the parameter exists for the enterprise overlay to scope a link.
    def resolve_default(provider:, account: nil)
      return nil if provider.blank?

      new(provider: provider, account: account).resolve_default
    end

    # Returns a Resolution: the plaintext for a static credential, a reference
    # marker for an oauth one, or a missing marker. Prefers an explicit
    # reference when given, and only then falls back to the provider default.
    def resolve_value(credential_id: nil, provider: nil, account: nil)
      credential =
        if credential_id.present?
          resolve_by_id(credential_id)
        else
          resolve_default(provider: provider, account: account)
        end

      build_resolution(credential)
    end

    private

    def build_resolution(credential)
      # An oauth row carries no value (the column is NULL by database CHECK),
      # so decrypting it would be both pointless and misleading.
      return Resolution.new(credential: credential, value: nil) if credential.nil? || credential.oauth?

      Resolution.new(credential: credential, value: Ai::CredentialDecryptor.decrypt(credential.value))
    end
  end

  def initialize(provider:, account: nil)
    @provider = provider
    @account = account
  end

  def resolve_default
    Ai::ScopeChain.resolve { |scope| credential_for(scope) }
  end

  private

  def credential_for(scope)
    Ai::IntegrationCredential
      .active
      .for_scope(scope.to_s)
      .for_provider(@provider)
      .order(created_at: :asc)
      .first
  end
end
