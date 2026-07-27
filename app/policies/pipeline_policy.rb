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
    permitted_read? && accessible_record?
  end

  def view?
    # Alias for show? - used by child controllers (pipeline_stages, pipeline_items, ...)
    show?
  end

  def create?
    # Administrators or users with pipelines.create permission can create pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.create')
  end

  def update?
    permitted_write? && accessible_record?
  end

  def destroy?
    permitted_delete? && accessible_record?
  end

  def archive?
    permitted_write? && accessible_record?
  end

  def set_as_default?
    permitted_write? && accessible_record?
  end

  def stats?
    permitted_read? && accessible_record?
  end

  # Answers the archive confirmation dialog, and the controller gates it on
  # `pipelines.update`. Authorizing it as a read would have quietly added a
  # `pipelines.read` requirement the endpoint never had.
  def dependents?
    permitted_write? && accessible_record?
  end

  private

  def permitted_read?
    @user&.administrator? || @user&.has_permission?('pipelines.read')
  end

  def permitted_write?
    @user&.administrator? || @user&.has_permission?('pipelines.update')
  end

  def permitted_delete?
    @user&.administrator? || @user&.has_permission?('pipelines.delete')
  end

  # EVO-2204: routes through the SAME Scope#resolve that filters #index, so detail and
  # list can never disagree. It is a READ predicate reused as the write gate — tightening
  # that is not local, pipeline_items authorizes card writes against the same `update?`.
  def accessible_record?
    scope.exists?(id: @record.id)
  end
end
