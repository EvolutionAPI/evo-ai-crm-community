class Api::V1::ProductCategoriesController < Api::V1::BaseController
  require_permissions({
                        index: 'products.read',
                        create: 'products.create'
                      })

  def index
    @categories = ProductCategory.all
    @categories = @categories.search(params[:q]) if params[:q].present?
    @categories = @categories.ordered.limit(50)

    success_response(
      data: @categories.map { |c| { id: c.id, name: c.name } },
      message: 'Product categories retrieved successfully'
    )
  end

  def create
    @category = ProductCategory.new(category_params)

    if @category.save
      success_response(
        data: { id: @category.id, name: @category.name },
        message: 'Product category created successfully',
        status: :created
      )
    else
      validation_error_response(@category)
    end
  end

  private

  def category_params
    params.require(:product_category).permit(:name)
  end

  def validation_error_response(record)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: format_validation_errors(record.errors),
      status: :unprocessable_entity
    )
  end
end