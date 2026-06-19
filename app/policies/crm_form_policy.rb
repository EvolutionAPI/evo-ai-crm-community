class CrmFormPolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @scope = scope
    end

    def resolve
      scope.all
    end
  end

  def index?
    @user&.administrator? || @user&.has_permission?('crm_forms.read')
  end

  def show?
    @user&.administrator? || @user&.has_permission?('crm_forms.read')
  end

  def create?
    @user&.administrator? || @user&.has_permission?('crm_forms.create')
  end

  def update?
    @user&.administrator? || @user&.has_permission?('crm_forms.update')
  end

  def destroy?
    @user&.administrator? || @user&.has_permission?('crm_forms.delete')
  end
end
