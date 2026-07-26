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
      # EVO-2222: single place the pipeline list surfaces are scoped from (#index and
      # the by_* endpoints go through policy_scope). Mirrors Pipeline.accessible_by —
      # public + owned + default + team (members of the pipeline's teams). No
      # administrator bypass: accessible_by has never granted admins other users'
      # private pipelines, and the list has always behaved that way.
      #
      # Service-to-service calls are the one exception: they carry no Current.user by
      # design (check_permission! already grants them elevated access), so scoping them
      # by a nil user would quietly return public+default instead of what was asked for.
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
