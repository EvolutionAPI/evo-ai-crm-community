# frozen_string_literal: true

module Templates
  # Which relation the export may read for a category, given the caller.
  #
  # A router, not a policy: it says WHICH rule governs a category and delegates to
  # it, so the export never second-guesses an answer that belongs to a model or a
  # policy. Both enumeration points (the inventory and BundleBuilder#base_relation)
  # go through here, because a fix applied to one and not the other still leaks
  # through an explicit id while the UI looks correct.
  module VisibilityScope
    # Categories that are not account-wide, mapped to the rule that already governs
    # every other read of them. Everything absent is shared, and scoping it would
    # silently drop assets from bundles.
    RULES = {
      'macros' => ->(user) { ::Macro.with_visibility(user, {}) },
      # Same object Pundit builds for `policy_scope(Pipeline)`, called rather than
      # copied: the service branch and the deliberate lack of an admin bypass are
      # the policy's answers to give.
      'pipelines' => lambda { |user|
        ::PipelinePolicy::Scope.new(
          { user: user, service_authenticated: Current.service_authenticated }, ::Pipeline
        ).resolve
      }
    }.freeze

    def self.for(category, model, user)
      rule = RULES[category]
      rule ? rule.call(user) : model.all
    end
  end
end
