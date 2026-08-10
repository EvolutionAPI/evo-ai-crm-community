class Api::V1::CustomFiltersController < Api::V1::BaseController
  require_permissions({
    index: 'custom_filters.read',
    show: 'custom_filters.read',
    create: 'custom_filters.write',
    update: 'custom_filters.write',
    destroy: 'custom_filters.delete'
  })
  before_action :fetch_custom_filters, only: [:index]
  before_action :fetch_custom_filter, only: [:show, :update, :destroy]
  DEFAULT_FILTER_TYPE = 'conversation'.freeze

  def index
    success_response(
      data: CustomFilterSerializer.serialize_collection(@custom_filters),
      message: 'Custom filters retrieved successfully'
    )
  end

  def show
    success_response(
      data: CustomFilterSerializer.serialize(@custom_filter),
      message: 'Custom filter retrieved successfully'
    )
  end

  def create
    @custom_filter = CustomFilter.new(
      permitted_payload.merge(user: Current.user)
    )
    
    if @custom_filter.save
      success_response(
        data: CustomFilterSerializer.serialize(@custom_filter),
        message: 'Custom filter created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @custom_filter.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def update
    if @custom_filter.update(permitted_payload)
      success_response(
        data: CustomFilterSerializer.serialize(@custom_filter),
        message: 'Custom filter updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @custom_filter.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @custom_filter.destroy
    success_response(
      data: { id: @custom_filter.id },
      message: 'Custom filter deleted successfully'
    )
  end

  private

  def fetch_custom_filters
    @custom_filters = CustomFilter.where(
      user: Current.user,
      filter_type: permitted_params[:filter_type] || DEFAULT_FILTER_TYPE
    )
  end

  def fetch_custom_filter
    @custom_filter = CustomFilter.where(
      user: Current.user
    ).find(permitted_params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::CUSTOM_FILTER_NOT_FOUND,
      "Custom filter with id #{permitted_params[:id]} not found",
      status: :not_found
    )
  end

  def permitted_payload
    params.require(:custom_filter).permit(
      :name,
      :filter_type,
      query: {}
    )
  end

  def permitted_params
    params.permit(:id, :filter_type)
  end
end
