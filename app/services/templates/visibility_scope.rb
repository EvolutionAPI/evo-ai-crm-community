# frozen_string_literal: true

module Templates
  # Which relation the export may read for a category, given the caller.
  #
  # CRM-205 scoped macros; CRM-206 scopes pipelines. Until the second case existed
  # the rule lived in two places on purpose — ExportService.exportable_inventory
  # and BundleBuilder#base_relation — because designing the abstraction from a
  # single example would have been guesswork.
  #
  # With two categories that reasoning flips. Each scoped category needs the same
  # decision made in BOTH places, so leaving it spread out means four sites that
  # can drift, and the failure mode is silent: a fix applied to the inventory but
  # not to base_relation still leaks through an explicit id, and the export looks
  # correct in the UI.
  #
  # What this class deliberately does NOT do is unify the rules themselves. They
  # have genuinely different shapes and each belongs to its model:
  #
  #   macros    -> Macro.with_visibility(user, {})  — a class method that already
  #                answers for userless and service callers
  #   pipelines -> Pipeline.accessible_by(user)     — a plain scope, with the
  #                userless/service decision living in PipelinePolicy::Scope
  #
  # This is a router, not a policy. It says WHICH rule governs a category; the
  # models keep saying WHAT the rule is. That matters because the export must
  # never second-guess those answers — deciding for itself is exactly what the
  # CRM-205 review flagged as its High finding.
  module VisibilityScope
    # Categories whose rows are not account-wide. Everything else (labels,
    # canned_responses, message_templates, teams, inboxes, custom_attributes,
    # agents) is shared, and scoping it would silently drop assets from bundles.
    SCOPED_CATEGORIES = %w[macros pipelines].freeze

    class << self
      # Returns the relation the caller is allowed to read for this category.
      # `model` is passed in so the caller keeps owning its MODEL_MAP.
      def for(category, model, user)
        case category
        when 'macros' then ::Macro.with_visibility(user, {})
        when 'pipelines' then pipelines_for(user)
        else model.all
        end
      end

      def scoped?(category)
        SCOPED_CATEGORIES.include?(category)
      end

      private

      # Mirrors PipelinePolicy::Scope#resolve, which is where this rule already
      # lives for every other pipeline read path.
      #
      # The service branch is not an afterthought: a service token authenticates
      # with NO user and is already elevated by check_permission!, so scoping it
      # by a nil user would answer with public + default only and silently shrink
      # bundles that used to be complete.
      #
      # `accessible_by(nil)` is safe for a bare userless caller — it uses
      # `user&.id` internally and yields public + default, the pipeline analogue
      # of the macro `global` fallback. No NoMethodError, no fail-open.
      def pipelines_for(user)
        return ::Pipeline.all if Current.service_authenticated == true

        ::Pipeline.accessible_by(user)
      end
    end
  end
end
