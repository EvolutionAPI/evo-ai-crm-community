class InstallationConfigPolicy < ApplicationPolicy
  # Gate of /api/v1/admin/* — the controller declares no require_permissions.
  # The grant alone: `administrator?` short-circuited it and is true for account_owner,
  # whose role deliberately lacks installation_configs.manage in the auth seed.
  def manage?
    @user&.has_permission?('installation_configs.manage') || false
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
