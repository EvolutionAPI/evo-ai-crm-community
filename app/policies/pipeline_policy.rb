class PipelinePolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @scope = scope
    end

    def resolve
      # No administrator bypass here, deliberately: admins never reached other users'
      # private pipelines. Service-to-service calls carry no Current.user by design, so
      # scoping them by nil would answer with public+default only.
      return scope.all if user_context[:service_authenticated] == true

      scope.accessible_by(user)
    end
  end

  def index?
    # Administrators or users with pipelines.read permission can list pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.read')
  end

  def show?
    # Administrators or users with pipelines.read permission can view pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.read')
  end

  def view?
    # Alias for show? - used by some controllers
    show?
  end

  def create?
    # Administrators or users with pipelines.create permission can create pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.create')
  end

  def update?
    # Administrators or users with pipelines.update permission can update pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.update')
  end

  def destroy?
    # Administrators or users with pipelines.delete permission can delete pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.delete')
  end

  def archive?
    # Administrators or users with pipelines.update permission can archive pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.update')
  end

  def stats?
    # Administrators or users with pipelines.read permission can view pipeline statistics
    @user&.administrator? || @user&.has_permission?('pipelines.read')
  end
end
