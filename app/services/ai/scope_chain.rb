# frozen_string_literal: true

# The ordered scope chain, and the single owner of how it is walked.
#
# Extracted from Ai::CredentialResolver (story 1.2) when story 2.2 added a
# second resolver for integration credentials. Copying the traversal instead
# would have created two truths about precedence, and the enterprise overlay
# inserts an `agency` link between installation and account: with two copies it
# would land in one of them and be forgotten in the other, which is exactly the
# divergence story 1.2 exists to prevent.
#
# Scopes run from the most GENERIC to the most SPECIFIC, and the most specific
# link wins. It is deliberately a list, not a pair, so inserting a link changes
# precedence without touching any resolution logic. There is no
# `if account then ... else installation` anywhere on purpose.
module Ai::ScopeChain
  SCOPE_CHAIN = %i[installation account].freeze

  module_function

  # Walks the chain from the most specific link to the most generic one and
  # returns the first result the block yields, or nil when no link offers one.
  #
  # The caller supplies the per-scope lookup: the two resolvers filter by
  # different things (consumer compatibility for AI credentials, provider for
  # integration ones), and pushing that into here would make this module know
  # about both.
  def resolve(&)
    SCOPE_CHAIN.reverse.lazy.filter_map(&).first
  end
end
