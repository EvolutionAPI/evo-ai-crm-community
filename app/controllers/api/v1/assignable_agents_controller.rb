class Api::V1::AssignableAgentsController < Api::V1::BaseController
  before_action :fetch_inboxes

  def index
    # @inboxes is already restricted to the caller's accessible inboxes
    # (see fetch_inboxes) — requested inboxes the caller cannot see are filtered
    # out gracefully rather than raising a 403.
    # Assignable agents are the members shared across the requested (and
    # caller-accessible) inboxes. The previous implementation also unioned
    # `User.with_role(:administrator)` — a rolify method that does not exist in
    # Community (no rolify gem; admin status is derived per-request from the
    # auth role in `Current`, not from a queryable local table). It raised
    # NoMethodError on every call. Dropped it: assignment targets an inbox, so
    # inbox membership is the correct and complete source here.
    agent_ids = @inboxes.map do |inbox|
      inbox.members.pluck(:user_id)
    end
    agent_ids = agent_ids.inject(:&) || []
    @assignable_agents = User.where(id: agent_ids)
    
    success_response(
      data: UserSerializer.serialize_collection(@assignable_agents),
      message: 'Assignable agents retrieved successfully'
    )
  end

  private

  def fetch_inboxes
    # Restrict to inboxes the caller can access (admin/read_all/opt-in via
    # assigned_inboxes); degrade to all when no request user is set.
    scope = current_user&.assigned_inboxes || Inbox.all
    @inboxes = scope.where(id: permitted_params[:inbox_ids])
  end

  def permitted_params
    params.permit(inbox_ids: [])
  end
end
