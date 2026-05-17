# frozen_string_literal: true

module EvoExtensionPoints
  # Feature gating extension point. Community default: every flag is enabled.
  # An external consumer (e.g. an enterprise licensing gem) can replace this
  # implementation via EvoExtensionPoints.replace(:feature_gate) { |flag, **ctx| ... }
  # without patching community source. See EXTENSION_POINTS.md at the repo root.
  module FeatureGate
    DEFAULT_IMPL = ->(_flag, **_context) { true }

    class << self
      def feature_enabled?(flag, **context)
        impl = EvoExtensionPoints.impl_for(:feature_gate) || DEFAULT_IMPL
        impl.call(flag, **context)
      end
    end
  end
end
