# frozen_string_literal: true

module EvoExtensionPoints
  # Tenant context extension point. Community default: single-tenant mode —
  # current_tenant_id is always nil and with_tenant is a pass-through.
  # See EXTENSION_POINTS.md.
  module TenantContext
    DEFAULT_CURRENT_ID = -> {}
    DEFAULT_WITH_TENANT = ->(_id, &block) { block&.call }

    class << self
      def current_tenant_id
        impl = EvoExtensionPoints.impl_for(:tenant_context_current_id) || DEFAULT_CURRENT_ID
        impl.call
      end

      def with_tenant(id, &)
        impl = EvoExtensionPoints.impl_for(:tenant_context_with_tenant) || DEFAULT_WITH_TENANT
        impl.call(id, &)
      end
    end
  end
end
