# frozen_string_literal: true

# Resolves which AI credential is in effect for a given feature.
#
# This is the ONLY owner of the precedence rule. The core service stores the
# scope but does not resolve inheritance: duplicating the rule on both sides
# guarantees divergence at the first bugfix.
#
# Scopes form an ORDERED CHAIN from the most generic to the most specific, and
# the most specific link wins. It is deliberately a list, not a pair: the
# enterprise roadmap adds an `agency` link between installation and account, and
# it must be able to do that by inserting into the chain — never by rewriting
# the resolution logic. There is no `if account then ... else installation` here
# on purpose.
#
# `account:` is threaded through the chain rather than queried: the community
# CRM is single-tenant and has no accounts table, so nothing filters on it. The
# parameter exists so the enterprise overlay can scope a link without changing
# this class.
class Ai::CredentialResolver
  SCOPE_CHAIN = %i[installation account].freeze

  # Returns the credential record in effect, or nil when no link in the chain
  # offers a usable one. Never raises for "nothing configured" — that is an
  # expected state.
  def self.resolve(for_consumer:, account: nil)
    new(consumer: for_consumer, account: account).resolve
  end

  # Returns the plaintext key in effect, decrypting the registry value or
  # falling back to the legacy sources. This is what consumers call.
  # `legacy_hook` is the caller's own openai Hook when it has one, so the
  # fallback reads the same record the consumer used before this story.
  def self.resolve_key(for_consumer:, account: nil, legacy_hook: nil)
    new(consumer: for_consumer, account: account, legacy_hook: legacy_hook).resolve_key
  end

  def initialize(consumer:, account: nil, legacy_hook: nil)
    @consumer = consumer&.to_sym
    @account = account
    @legacy_hook = legacy_hook
  end

  def resolve
    return nil unless Ai::ConsumerCompatibility.known?(@consumer)

    # Most specific first: the chain is read backwards, so inserting a link
    # changes precedence without touching this method.
    SCOPE_CHAIN.reverse.lazy.filter_map { |scope| credential_for(scope) }.first
  end

  def resolve_key
    credential = resolve
    key = credential && Ai::CredentialDecryptor.decrypt(credential.key)
    return key if key.present?

    legacy_key
  end

  private

  # LEGACY FALLBACK — REMOVED BY STORY 1.6.
  #
  # The pre-registry precedence (global config wins, account hook is the
  # fallback) does not disappear in this story: it drops one level and becomes
  # the last, most generic link. Installations that have not migrated keep
  # working, and a credential registered on the new screen is never shadowed by
  # legacy configuration, because the chain above is tried first.
  #
  # It lives here, inside the resolver, and never spread across consumers.
  def legacy_key
    return nil unless Ai::ConsumerCompatibility.accepts?(@consumer, 'openai')

    global_key = GlobalConfigService.load('OPENAI_API_SECRET', nil)
    return global_key if global_key.present?

    legacy_hook_key
  rescue StandardError => e
    Rails.logger.error("Ai::CredentialResolver legacy fallback: #{e.class}: #{e.message}")
    nil
  end

  # Consumers holding a Hook pass it in, so the fallback reads the very record
  # they read before. Without one, the account-level openai hook is used.
  def legacy_hook_key
    hook = @legacy_hook || Integrations::Hook.find_by(app_id: 'openai')
    hook&.settings&.dig('api_key').presence
  end

  def credential_for(scope)
    candidates(scope).find { |credential| accepted?(credential) }
  end

  def candidates(scope)
    Ai::Credential
      .active
      .for_scope(scope.to_s)
      .order(created_at: :asc)
  end

  # A credential the consumer cannot speak to is skipped, so resolution falls
  # through to a more generic link instead of failing at the provider (FR18).
  def accepted?(credential)
    Ai::ConsumerCompatibility.accepts?(@consumer, credential.provider)
  end
end
