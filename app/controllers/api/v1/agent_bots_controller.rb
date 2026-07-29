class Api::V1::AgentBotsController < Api::V1::BaseController
  require_permissions({
    index: 'agent_bots.read',
    show: 'agent_bots.read',
    create: 'agent_bots.create',
    update: 'agent_bots.update',
    destroy: 'agent_bots.delete',
    avatar: 'agent_bots.update',
    reset_access_token: 'agent_bots.update'
  })

  include Api::V1::ResourceLimitsHelper

  before_action :agent_bot, except: [:index, :create]
  before_action :validate_agent_bot_limit, only: [:create]

  def index
    @agent_bots = AgentBot.all
    
    apply_pagination
    
    paginated_response(
      data: AgentBotSerializer.serialize_collection(@agent_bots),
      collection: @agent_bots
    )
  end

  def show
    success_response(
      data: AgentBotSerializer.serialize(@agent_bot),
      message: 'Agent bot retrieved successfully'
    )
  end

  def create
    @agent_bot = AgentBot.create!(permitted_params.except(:avatar_url))
    process_avatar_from_url
    
    success_response(
      data: AgentBotSerializer.serialize(@agent_bot),
      message: 'Agent bot created successfully',
      status: :created
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message
    )
  end

  def update
    @agent_bot.update!(permitted_params.except(:avatar_url))
    process_avatar_from_url
    
    success_response(
      data: AgentBotSerializer.serialize(@agent_bot),
      message: 'Agent bot updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message
    )
  end

  def avatar
    @agent_bot.avatar.purge if @agent_bot.avatar.attached?
    
    success_response(
      data: AgentBotSerializer.serialize(@agent_bot),
      message: 'Avatar removed successfully'
    )
  end

  def destroy
    if @agent_bot.destroy
      success_response(
        data: nil,
        message: 'Agent bot deleted successfully'
      )
    else
      # Try safe destroy as fallback
      Rails.logger.warn "Normal destroy failed for AgentBot #{@agent_bot.id}, trying safe_destroy"
      if @agent_bot.safe_destroy
        success_response(
          data: nil,
          message: 'Agent bot deleted successfully'
        )
      else
        error_response(
          ApiErrorCodes::CANNOT_DELETE_RESOURCE,
          @agent_bot.errors.full_messages.join(', ')
        )
      end
    end
  rescue StandardError => e
    Rails.logger.error "Failed to destroy AgentBot #{@agent_bot.id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    # Last resort: try safe destroy
    Rails.logger.warn "Attempting safe_destroy as last resort for AgentBot #{@agent_bot.id}"
    if @agent_bot.safe_destroy
      success_response(
        data: nil,
        message: 'Agent bot deleted successfully'
      )
    else
      error_response(
        ApiErrorCodes::INTERNAL_ERROR,
        "Failed to delete agent bot: #{e.message}"
      )
    end
  end

  def reset_access_token
    @agent_bot.access_token.regenerate_token
    @agent_bot.reload
    
    success_response(
      data: AgentBotSerializer.serialize(@agent_bot),
      message: 'Access token regenerated successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      e.message
    )
  end

  private

  def agent_bot
    @agent_bot = AgentBot.find(params[:id])
  end

  def permitted_params
    params.permit(
      :name, :description, :outgoing_url, :avatar, :avatar_url, :bot_type, :bot_provider, :api_key, :credential_id, :message_signature,
      :text_segmentation_enabled, :text_segmentation_limit, :text_segmentation_min_size, :delay_per_character,
      :debounce_time,
      bot_config: {}
    )
  end

  def process_avatar_from_url
    ::Avatar::AvatarFromUrlJob.perform_later(@agent_bot, params[:avatar_url]) if params[:avatar_url].present?
  end
end
