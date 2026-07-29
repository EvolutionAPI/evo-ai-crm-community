# frozen_string_literal: true

# Resolves which integration credential is in effect: the Dify key, the n8n
# basic auth, an MCP header, the Knowledge Nexus key.
#
# It reuses the chain mechanic of Ai::CredentialResolver through
# Ai::ScopeChain rather than reimplementing precedence — two copies of the rule
# diverge at the first bugfix, which is what story 1.2 exists to prevent.
#
# The deliberate difference from the AI credential resolver: here the normal
# case is a REFERENCE. A Dify agent uses the key of that Dify, not "the default
# key", so consumers point at one credential by id. The chain still exists, for
# the narrower case of a scope default per provider (an installation-wide
# ElevenLabs serving every account). Both live here so consumers never resolve
# an id by hand and spread the rule again.
class Ai::IntegrationCredentialResolver
  # Alias of the shared chain, kept for readability at call sites. It is the
  # SAME frozen array as Ai::ScopeChain::SCOPE_CHAIN, not a copy.
  SCOPE_CHAIN = Ai::ScopeChain::SCOPE_CHAIN

  # The outcome of resolving a VALUE. Three states that callers must be able to
  # tell apart:
  #
  #   missing   — nothing usable is configured
  #   reference — the credential is an oauth connection whose secret lives in
  #               another store; the caller reads it there, and the vault never
  #               owned it (a copy would go stale on the first refresh)
  #   value     — a static secret, decrypted and ready to use
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

    # Returns the credential that is the default for a provider, walking the
    # chain from the most specific link to the most generic one, or nil when no
    # link offers one.
    #
    # `account:` is threaded rather than queried, exactly as story 1.2 decided:
    # the community CRM is single-tenant and has no accounts table. The
    # parameter exists so the enterprise overlay can scope a link without
    # rewriting this class.
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
