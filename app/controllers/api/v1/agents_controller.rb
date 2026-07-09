class Api::V1::AgentsController < Api::V1::BaseController
  # This controller proxies AI-agent CRUD to evo-core (EvoAiCoreService), so its
  # gate is `ai_agents.*` — the same resource the frontend already gates the AI
  # screen with. The dead twin `agents.*` was consolidated away (EVO-2072).
  require_permissions({
    index: 'ai_agents.read',
    create: 'ai_agents.create',
    bulk_create: 'ai_agents.create',
    update: 'ai_agents.update',
    destroy: 'ai_agents.delete'
  })
  
  
  def index
    result = EvoAiCoreService.list_agents(index_params, request.headers)
    render json: result
  end

  def create
    result = EvoAiCoreService.create_agent(agent_params, request.headers)
    render json: result, status: :created
  end

  def update
    result = EvoAiCoreService.update_agent(params[:id], agent_params, request.headers)
    render json: result
  end

  def destroy
    EvoAiCoreService.delete_agent(params[:id], request.headers)
    head :no_content
  end
  
  private
  
  
  def index_params
    params.permit(:skip, :limit, :folder_id, :page, :pageSize)
  end
  
  def agent_params
    params.permit(
      :name, 
      :description, 
      :type, 
      :model, 
      :api_key_id, 
      :instruction, 
      :card_url, 
      :folder_id, 
      :role,
      :goal,
      config: {}
    )
  end
end