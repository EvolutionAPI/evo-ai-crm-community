class InstallationConfigPolicy < ApplicationPolicy
  # Sole gate of /api/v1/admin/* — that controller declares no require_permissions.
  # The grant is the only term on purpose: `administrator?` short-circuited it and
  # is true for account_owner, whose role deliberately lacks the grant in the auth seed.
  def manage?
    !!@user&.has_permission?('installation_configs.manage')
  end

  def index?
    manage?
  end

  def show?
    manage?
  end

  def create?
    manage?
  end

  def update?
    manage?
  end

  def destroy?
    manage?
  end
end
