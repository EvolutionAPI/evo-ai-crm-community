# frozen_string_literal: true

# The ordered scope chain and the single owner of how it is walked, shared by
# both resolvers: two copies of the traversal would be two truths about
# precedence, and the enterprise overlay's `agency` link would land in one and
# be forgotten in the other.
#
# Most GENERIC to most SPECIFIC, and the most specific wins. A list and not a
# pair, so inserting a link changes precedence without touching any logic.
module Ai::ScopeChain
  SCOPE_CHAIN = %i[installation account].freeze

  module_function

  # Walks from the most specific link to the most generic, returning the first
  # result the block yields. The caller supplies the per-scope lookup: the two
  # resolvers filter by different things, and knowing about both would couple
  # this module to each.
  def resolve(&)
    SCOPE_CHAIN.reverse.lazy.filter_map(&).first
  end
end
