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

  # Returns the credential in effect, or nil when no link in the chain offers a
  # usable one. Never raises for "nothing configured" — that is an expected
  # state, and callers fall back to their legacy sources until story 1.6.
  def self.resolve(for_consumer:, account: nil)
    new(consumer: for_consumer, account: account).resolve
  end

  def initialize(consumer:, account: nil)
    @consumer = consumer&.to_sym
    @account = account
  end

  def resolve
    return nil unless Ai::ConsumerCompatibility.known?(@consumer)

    # Most specific first: the chain is read backwards, so inserting a link
    # changes precedence without touching this method.
    SCOPE_CHAIN.reverse.lazy.filter_map { |scope| credential_for(scope) }.first
  end

  private

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
