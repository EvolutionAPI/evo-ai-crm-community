# frozen_string_literal: true

# Multi-tenant evo-flow requires the CALLER's tenant and identity on every
# proxied request: X-Evo-Tenant-Id scopes, and the runtime-context enricher
# reads the user from the JWT `sub` of the Authorization header (authentication
# itself stays on the integration key, which the bearer guard honors first).
# Without them evo-flow answers 401 TENANT_REQUIRED even to the proxy.
# Single-tenant deployments send neither header and nothing changes.
module EvoFlowTenantPassthrough
  extend ActiveSupport::Concern

  private

  def evo_flow_passthrough_headers
    {
      'X-Evo-Tenant-Id' => request.headers['X-Evo-Tenant-Id'],
      'Authorization' => request.headers['Authorization']
    }.compact
  end
end
