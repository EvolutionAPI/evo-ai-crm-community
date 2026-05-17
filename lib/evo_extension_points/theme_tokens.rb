# frozen_string_literal: true

module EvoExtensionPoints
  # Theme tokens extension point. Community default: the canonical Evolution
  # palette and typography tokens. Token keys mirror the public CSS variable
  # contract declared in EXTENSION_POINTS.md of the React frontend
  # (story 0.3); keep both in sync.
  module ThemeTokens
    DEFAULT_TOKENS = {
      '--evo-color-primary-500' => '#00ffa7',
      '--evo-color-primary-foreground' => '#0b0f14',
      '--evo-color-accent-500' => '#00ffa7',
      '--evo-color-background' => '#0b0f14',
      '--evo-color-foreground' => '#e6f1ec',
      '--evo-font-sans' => 'Inter, system-ui, sans-serif'
    }.freeze

    DEFAULT_IMPL = ->(_scope) { DEFAULT_TOKENS.dup }

    class << self
      def defaults(scope: :default)
        impl = EvoExtensionPoints.impl_for(:theme_tokens) || DEFAULT_IMPL
        impl.call(scope)
      end
    end
  end
end
