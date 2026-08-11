class Api::V1::WebhooksController < Api::V1::BaseController
  require_permissions({
    index: 'webhooks.read',
    create: 'webhooks.write',
    update: 'webhooks.write',
    destroy: 'webhooks.delete'
  })

  before_action :fetch_webhook, only: [:update, :destroy]

  def index
    @webhooks = Webhook.all
    
    apply_pagination
    
    paginated_response(
      data: WebhookSerializer.serialize_collection(@webhooks),
      collection: @webhooks,
      message: 'Webhooks retrieved successfully'
    )
  end

  def create
    @webhook = Webhook.new(webhook_create_params)
    @webhook.save!
    
    success_response(
      data: WebhookSerializer.serialize(@webhook),
      message: 'Webhook created successfully',
      status: :created
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message
    )
  end

  def update
    @webhook.update!(webhook_update_params)
    
    success_response(
      data: WebhookSerializer.serialize(@webhook),
      message: 'Webhook updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message
    )
  end

  def destroy
    @webhook.destroy!
    
    success_response(
      data: nil,
      message: 'Webhook deleted successfully'
    )
  rescue ActiveRecord::RecordNotDestroyed => e
    error_response(
      ApiErrorCodes::CANNOT_DELETE_RESOURCE,
      e.message
    )
  end

  private

  def webhook_create_params
    params.require(:webhook).permit(:inbox_id, :name, :url, subscriptions: [])
  end

  def webhook_update_params
    params.require(:webhook).permit(:name, subscriptions: [])
  end

  def fetch_webhook
    @webhook = Webhook.find(params[:id])
  end
end
