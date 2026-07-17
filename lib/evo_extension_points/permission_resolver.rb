# frozen_string_literal: true

module EvoExtensionPoints
  # Permission resolver extension point. Community default: delegate to the
  # auth-service exactly as before (account-blind check_user_permission), so a
  # community install behaves identically with or without a consumer. An
  # external consumer replaces it to resolve (user, scope, permission) — e.g.
  # account-aware RBAC:
  #   EvoExtensionPoints.replace(:permission_resolver) do |user_id:, permission_key:, scope_id: nil, **|
  #     ...
  #   end
  # NOT the CapabilityGate: that one gates capabilities/modules and its default
  # allows everything — routing permission checks through it would open the
  # community up. This seam's default preserves the current deny/grant.
  module PermissionResolver
    # The seam call site (evo_permission_concern#has_user_permission?) already
    # passes scope_id from RuntimeContext. Forward it so the auth-enterprise
    # overlay can filter derived roles by scope (EVO-2156 / AC1). Bifurcated on
    # scope_id.present? so the call arity in community (scope_id nil) stays
    # identical to the pre-EVO-2156 signature — AC2 (byte-for-byte parity) plus
    # a guard against surprising every existing spec that stubs the two-arg form.
    DEFAULT_IMPL = lambda do |user_id:, permission_key:, scope_id: nil, **_context|
      service = EvoAuthService.new
      if scope_id.present?
        service.check_user_permission(user_id, permission_key, scope_id: scope_id)
      else
        service.check_user_permission(user_id, permission_key)
      end
    end

    class << self
      def allowed?(user_id:, permission_key:, **context)
        impl = EvoExtensionPoints.impl_for(:permission_resolver) || DEFAULT_IMPL
        impl.call(user_id: user_id, permission_key: permission_key, **context)
      end
    end
  end
end
