class TeamMemberPolicy < ApplicationPolicy
  # team_members consolidated into teams (EVO-2070): membership reads gate on
  # teams.read and membership mutations on teams.update.
  def index?
    @user&.administrator? || @user&.has_permission?('teams.read')
  end

  def show?
    @user&.administrator? || @user&.has_permission?('teams.read')
  end

  def create?
    @user&.administrator? || @user&.has_permission?('teams.update')
  end

  def destroy?
    @user&.administrator? || @user&.has_permission?('teams.update')
  end

  def update?
    @user&.administrator? || @user&.has_permission?('teams.update')
  end
end
