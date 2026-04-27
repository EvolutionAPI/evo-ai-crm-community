class Api::V1::TeamMembersController < Api::V1::BaseController
  require_permissions({
    index: 'team_members.read',
    show: 'team_members.read',
    create: 'team_members.create',
    update: 'team_members.update',
    destroy: 'team_members.delete'
  })
  before_action :fetch_team

  def index
    @team_members = @team.team_members.map(&:user)

    success_response(
      data: TeamMemberSerializer.serialize_collection(@team_members),
      message: 'Team members retrieved successfully'
    )
  end

  def create
    ActiveRecord::Base.transaction do
      @team_members = @team.add_members(members_to_be_added_ids)
    end

    success_response(
      data: TeamMemberSerializer.serialize_collection(@team_members),
      message: 'Team members added successfully'
    )
  rescue ActiveRecord::RecordInvalid, ActiveRecord::InvalidForeignKey => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message,
      status: :unprocessable_entity
    )
  end

  def update
    ActiveRecord::Base.transaction do
      @team.add_members(members_to_be_added_ids)
      @team.remove_members(members_to_be_removed_ids)
    end
    @team_members = @team.members

    success_response(
      data: TeamMemberSerializer.serialize_collection(@team_members),
      message: 'Team members updated successfully'
    )
  rescue ActiveRecord::RecordInvalid, ActiveRecord::InvalidForeignKey => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message,
      status: :unprocessable_entity
    )
  end

  def destroy
    ActiveRecord::Base.transaction do
      @team.remove_members(params[:user_ids])
    end

    success_response(
      data: nil,
      message: 'Team members removed successfully'
    )
  rescue ActiveRecord::RecordInvalid, ActiveRecord::InvalidForeignKey => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message,
      status: :unprocessable_entity
    )
  end

  private

  def members_to_be_added_ids
    params[:user_ids] - current_members_ids
  end

  def members_to_be_removed_ids
    current_members_ids - params[:user_ids]
  end

  def current_members_ids
    @current_members_ids ||= @team.members.pluck(:id)
  end

  def fetch_team
    @team = Team.find(params[:team_id])
  end
end
