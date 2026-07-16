class InstallationConfigPolicy < ApplicationPolicy
  # This policy is the ONLY gate on Api::V1::Admin::BaseController (/api/v1/admin/*)
  # — that controller declares no require_permissions of its own.
  # While has_permission? was stubbed to `true`, manage? admitted ANY
  # authenticated user; since story 4.2 it resolves for real, so access is
  # administrator? (super_admin/account_owner/administrator/admin) or an
  # explicit installation_configs.manage grant.
  def manage?
    @user&.administrator? || @user&.has_permission?('installation_configs.manage')
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
