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
    DEFAULT_IMPL = lambda do |user_id:, permission_key:, **_context|
      EvoAuthService.new.check_user_permission(user_id, permission_key)
    end

    class << self
      def allowed?(user_id:, permission_key:, **context)
        impl = EvoExtensionPoints.impl_for(:permission_resolver) || DEFAULT_IMPL
        impl.call(user_id: user_id, permission_key: permission_key, **context)
      end
    end
  end
end
