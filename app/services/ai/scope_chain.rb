# frozen_string_literal: true

# The ordered scope chain and the single owner of how it is walked, shared by
# both resolvers: two copies of the traversal would be two truths about
# precedence, and an overlay's inserted link would land in one and be forgotten
# in the other.
#
# Most GENERIC to most SPECIFIC, and the most specific wins. A list and not a
# pair, so inserting a link changes precedence without touching any logic.
#
# The chain is a base seed (`BASE_CHAIN`) plus links added at boot via
# `insert_link`. An overlay reaches precedence it does not own by inserting into
# the list — never by reopening a resolver.
module Ai::ScopeChain
  BASE_CHAIN = %i[installation account].freeze

  # Built from the seed; only `insert_link` (at boot) and `reset!` (tests) mutate
  # it, so runtime reads need no lock.
  @chain = BASE_CHAIN.dup

  module_function

  # A defensive copy: the chain is mutated only through `insert_link`, never by a
  # caller holding the array.
  def chain
    @chain.dup.freeze
  end

  # The extension port. Inserts `scope` immediately before `before`, or does
  # nothing if it is already present. Idempotency is not cosmetic: a reloading
  # boot hook would otherwise grow the chain `agency, agency, agency` unnoticed.
  def insert_link(scope, before:)
    return @chain if @chain.include?(scope)

    index = @chain.index(before)
    raise ArgumentError, "unknown chain link: #{before.inspect}" unless index

    @chain.insert(index, scope)
  end

  # Restores the seed. For test isolation only — production never resets.
  def reset!
    @chain = BASE_CHAIN.dup
  end

  # Walks from the most specific link to the most generic, returning the first
  # result the block yields. The caller supplies the per-scope lookup: the two
  # resolvers filter by different things, and knowing about both would couple
  # this module to each.
  def resolve(&)
    @chain.reverse.lazy.filter_map(&).first
  end
end
