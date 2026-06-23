class Api::V1::Products::VariantsController < Api::V1::BaseController
  require_permissions({
    index:   'products.read',
    create:  'products.update',
    update:  'products.update',
    destroy: 'products.update'
  })

  before_action :fetch_product
  before_action :fetch_variant, only: %i[update destroy]

  def index
    paginated_response(
      data: ProductVariantSerializer.serialize_collection(@product.variants),
      collection: @product.variants,
      message: 'Product variants retrieved successfully'
    )
  end

  def create
    @variant = @product.variants.new(variant_params)

    if @variant.save
      success_response(
        data: ProductVariantSerializer.serialize(@variant),
        message: 'Product variant created successfully',
        status: :created
      )
    else
      validation_error_response(@variant)
    end
  end

  def update
    if @variant.update(variant_params)
      success_response(
        data: ProductVariantSerializer.serialize(@variant),
        message: 'Product variant updated successfully'
      )
    else
      validation_error_response(@variant)
    end
  end

  def destroy
    if @variant.destroy
      success_response(
        data: { id: @variant.id },
        message: 'Product variant deleted successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Variant is in use and cannot be deleted',
        details: format_validation_errors(@variant.errors),
        status: :unprocessable_entity
      )
    end
  end

  private

  def fetch_product
    @product = Product.find(params[:product_id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      "Product with id #{params[:product_id]} not found",
      status: :not_found
    )
  end

  def fetch_variant
    @variant = @product.variants.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      "Variant with id #{params[:id]} not found",
      status: :not_found
    )
  end

  def variant_params
    params
      .require(:variant)
      .permit(:name, :sku, :price_override, :stock_quantity, :position, attributes_data: {})
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
