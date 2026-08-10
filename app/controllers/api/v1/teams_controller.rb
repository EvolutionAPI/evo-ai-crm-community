class Api::V1::TeamsController < Api::V1::BaseController
  include Api::V1::ResourceLimitsHelper

  # Configuração de permissões - Define exatamente quais actions precisam de verificação
  require_permissions({
    index: 'teams.read',
    show: 'teams.read',
    create: 'teams.write', 
    update: 'teams.write',
    destroy: 'teams.delete'
  })

  before_action :fetch_team, only: [:show, :update, :destroy]
  before_action :validate_team_limit, only: [:create]

  def index
    @teams = Team.all
    
    apply_pagination
    
    paginated_response(
      data: TeamSerializer.serialize_collection(@teams, current_user_id: Current.user.id),
      collection: @teams,
      message: 'Teams retrieved successfully'
    )
  end

  def show
    success_response(
      data: TeamSerializer.serialize(@team, current_user_id: Current.user.id),
      message: 'Team retrieved successfully'
    )
  end

  def create
    @team = Team.new(team_params)
    
    if @team.save
      success_response(
        data: TeamSerializer.serialize(@team, current_user_id: Current.user.id),
        message: 'Team created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @team.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def update
    if @team.update(team_params)
      success_response(
        data: TeamSerializer.serialize(@team, current_user_id: Current.user.id),
        message: 'Team updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @team.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @team.destroy
    success_response(
      data: { id: @team.id },
      message: 'Team deleted successfully'
    )
  end

  private

  def fetch_team
    @team = Team.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::TEAM_NOT_FOUND,
      "Team with id #{params[:id]} not found",
      status: :not_found
    )
  end

  def team_params
    params.require(:team).permit(:name, :description, :allow_auto_assign)
  end
end
