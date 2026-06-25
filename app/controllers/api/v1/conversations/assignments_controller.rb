class Api::V1::Conversations::AssignmentsController < Api::V1::Conversations::BaseController
  # assigns agent/team to a conversation
  def create
    if params.key?(:assignee_id)
      set_agent
    elsif params.key?(:team_id)
      set_team
    else
      error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        'Either assignee_id or team_id is required',
        status: :bad_request
      )
    end
  end

  private

  def set_agent
    # Blank assignee_id is a legitimate intent to unassign (remove the agent).
    # A present-but-unresolvable id must NOT silently zero the existing assignee.
    if params[:assignee_id].blank?
      @conversation.update!(assignee: nil)
      return success_response(
        data: {},
        message: 'Agent assignment removed successfully'
      )
    end

    @agent = User.find_by(id: params[:assignee_id])
    return unresolvable_id(:assignee_id, 'Assignee not found') if @agent.nil?

    @conversation.update!(assignee: @agent)
    success_response(
      data: { assignee: UserSerializer.serialize(@agent) },
      message: 'Agent assigned successfully'
    )
  end

  def set_team
    # Blank team_id is a legitimate intent to unassign (remove the team).
    # A present-but-unresolvable id must NOT silently zero the existing team.
    if params[:team_id].blank?
      @conversation.update!(team: nil)
      return success_response(
        data: { team: nil },
        message: 'Team assignment removed successfully'
      )
    end

    @team = Team.find_by(id: params[:team_id])
    return unresolvable_id(:team_id, 'Team not found') if @team.nil?

    @conversation.update!(team: @team)
    success_response(
      data: { team: TeamSerializer.serialize(@team) },
      message: 'Team assigned successfully'
    )
  end

  # A present-but-unresolvable id is rejected WITHOUT touching the existing
  # assignee/team. Community has no account FK on User/Team, so "out of account"
  # is descoped to "unresolvable id" (see EVO-1914). Uses the positional
  # `error_response` signature (code, message) — a prior bug passed it by keyword
  # and masked the real error as a 500.
  def unresolvable_id(field, message)
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      message,
      details: { field => params[field] },
      status: :not_found
    )
  end
end
