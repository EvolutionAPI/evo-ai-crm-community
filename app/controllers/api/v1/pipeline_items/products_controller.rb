class Api::V1::PipelineItems::ProductsController < Api::V1::BaseController
  require_permissions({
    index:   'pipelines.read',
    create:  'pipelines.update',
    update:  'pipelines.update',
    destroy: 'pipelines.update'
  })

  # Mirrors PipelineItemsController: reads gate on :view?, mutations on :update?.
  WRITE_ACTIONS = %w[create update destroy].freeze

  before_action :fetch_pipeline_item
  # EVO-2204: the item was resolved by a bare find that ignored :pipeline_id entirely,
  # so the products and the deal value of an item sitting in another user's private
  # pipeline were readable and editable. Authorize the item's own pipeline, which also
  # closes the mismatch between the id in the URL and the item actually loaded.
  before_action :authorize_pipeline!
  before_action :fetch_link, only: %i[update destroy]

  def index
    links = @pipeline_item.pipeline_item_products.includes(:product, :product_variant)

    success_response(
      data: PipelineItemProductSerializer.serialize_collection(links),
      meta: { total_value: @pipeline_item.total_value.to_f },
      message: 'Pipeline item products retrieved successfully'
    )
  end

  # POST /api/v1/pipeline_items/:pipeline_item_id/products
  # Body: { product_id, product_variant_id?, quantity, notes? }
  def create
    record = @pipeline_item.pipeline_item_products.new(create_params)
    apply_actor(record)

    if record.save
      success_response(
        data: PipelineItemProductSerializer.serialize(record),
        message: 'Product linked to pipeline item successfully',
        status: :created
      )
    else
      validation_error_response(record)
    end
  end

  # PATCH /api/v1/pipeline_items/:pipeline_item_id/products/:id
  def update
    if @link.update(update_params)
      success_response(
        data: PipelineItemProductSerializer.serialize(@link),
        message: 'Pipeline item product updated successfully'
      )
    else
      validation_error_response(@link)
    end
  end

  def destroy
    if @link.destroy
      success_response(
        data: { id: @link.id },
        message: 'Pipeline item product removed successfully'
      )
    else
      validation_error_response(@link)
    end
  end

  private

  def fetch_pipeline_item
    @pipeline_item = PipelineItem.find(params[:pipeline_item_id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      "Pipeline item with id #{params[:pipeline_item_id]} not found",
      status: :not_found
    )
  end

  # Automations and the ADK tool call this with a service token and no Current.user —
  # apply_actor already reads that shape from the body, so the bypass is required.
  def authorize_pipeline!
    return if service_authenticated? || @pipeline_item.nil?

    authorize @pipeline_item.pipeline, WRITE_ACTIONS.include?(action_name) ? :update? : :view?
  end

  def fetch_link
    @link = @pipeline_item.pipeline_item_products.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      "Pipeline item product link with id #{params[:id]} not found",
      status: :not_found
    )
  end

  def create_params
    params.permit(:product_id, :product_variant_id, :quantity, :notes)
  end

  def update_params
    # Locked price/currency stay frozen; only mutable attributes here.
    params.permit(:quantity, :notes)
  end

  # The caller can be a real user, an AutomationRule, or the AI agent that
  # invoked the ADK tool. We trust Current.user for HTTP requests; service
  # tokens (used by the processor) pass a `created_by_type`/`created_by_id`
  # tuple explicitly in the body so we record exactly who scored the sale.
  def apply_actor(record)
    if Current.user.present?
      record.created_by_type ||= 'User'
      record.created_by_id   ||= Current.user.id
      return
    end

    explicit_type = params[:created_by_type].to_s
    explicit_id   = params[:created_by_id]
    return unless PipelineItemProduct::ALLOWED_CREATED_BY_TYPES.include?(explicit_type)

    record.created_by_type ||= explicit_type
    record.created_by_id   ||= explicit_id
  end

  def validation_error_response(record)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: record.errors.full_messages,
      status: :unprocessable_entity
    )
  end
end
