class Api::V1::ProductsController < Api::V1::BaseController
  require_permissions({
                        index: 'products.read',
                        show: 'products.read',
                        create: 'products.create',
                        update: 'products.update',
                        destroy: 'products.delete',
                        bulk: 'products.create'
                      })

  before_action :fetch_product, only: %i[show update destroy]

  def index
    @products = filtered_products

    apply_pagination

    paginated_response(
      data: ProductSerializer.serialize_collection(@products),
      collection: @products,
      message: 'Products retrieved successfully'
    )
  end

  def show
    success_response(
      data: ProductSerializer.serialize(@product),
      message: 'Product retrieved successfully'
    )
  end

  def create
    @product = Product.new(product_params)

    if @product.save
      attach_images
      apply_labels
      success_response(
        data: ProductSerializer.serialize(@product.reload),
        message: 'Product created successfully',
        status: :created
      )
    else
      validation_error_response(@product)
    end
  end

  def update
    if @product.update(product_params)
      attach_images
      apply_labels
      success_response(
        data: ProductSerializer.serialize(@product.reload),
        message: 'Product updated successfully'
      )
    else
      validation_error_response(@product)
    end
  end

  def bulk
    items = extract_bulk_items
    return if items.nil?

    if bulk_dry_run?
      render_bulk_dry_run(Products::BulkImporter.new(items, dry_run: true).call)
    else
      created = Products::BulkImporter.new(items).call
      success_response(
        data: ProductSerializer.serialize_collection(created.map(&:reload)),
        meta: { created: created.size, updated: 0, skipped: 0 },
        message: "#{created.size} products created successfully",
        status: :created
      )
    end
  rescue Products::BulkImporter::BulkImportError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Bulk import failed; no products were created',
      details: e.errors_payload,
      status: :unprocessable_entity
    )
  end

  def destroy
    if @product.destroy
      success_response(
        data: { id: @product.id },
        message: 'Product deleted successfully'
      )
    else
      # restrict_with_error on pipeline_item_products / variants in use
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Product is in use and cannot be deleted',
        details: format_validation_errors(@product.errors),
        status: :unprocessable_entity
      )
    end
  end

  private

  def fetch_product
    @product = Product.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      "Product with id #{params[:id]} not found",
      status: :not_found
    )
  end

  def extract_bulk_items
    raw_items = params[:products]
    items = raw_items.is_a?(Array) || raw_items.is_a?(ActionController::Parameters) ? Array(raw_items) : []
    return reject_bulk(ApiErrorCodes::VALIDATION_ERROR, 'products array is required and must not be empty') if items.empty?
    return reject_bulk_limit(items.size) if items.size > Products::BulkImporter::MAX_ITEMS

    items
  end

  def reject_bulk(code, message, details: nil)
    error_response(code, message, details: details, status: :unprocessable_entity)
    nil
  end

  def bulk_dry_run?
    ActiveModel::Type::Boolean.new.cast(params[:dry_run])
  end

  def render_bulk_dry_run(result)
    success_response(
      data: {
        dry_run: true,
        would_create: result.would_create,
        would_update: [],
        would_skip: [],
        errors: result.errors
      },
      meta: {
        created: result.would_create.size,
        updated: 0,
        skipped: 0,
        errors: result.errors.size
      }
    )
  end

  def reject_bulk_limit(received)
    max = Products::BulkImporter::MAX_ITEMS
    reject_bulk(
      ApiErrorCodes::LIMIT_EXCEEDED,
      "Bulk import exceeds maximum of #{max} items per request",
      details: { max: max, received: received }
    )
  end

  def filtered_products
    scope = Product.all
    scope = scope.by_kind(params[:kind])
    scope = scope.by_status(params[:status])
    if params[:q].present?
      term = "%#{params[:q]}%"
      scope = scope.where('name ILIKE :t OR sku ILIKE :t OR description ILIKE :t', t: term)
    end
    scope.order_by_recent
  end

  def product_params
    params
      .require(:product)
      .permit(
        :name, :slug, :kind, :description, :sku,
        :default_price, :currency, :purchase_url,
        :status, :stock_quantity,
        metadata: {},
        variants_attributes: [
          :id, :_destroy, :name, :sku,
          :price_override, :stock_quantity, :position,
          { attributes_data: {} }
        ]
      )
  end

  def label_list_param
    raw = params.dig(:product, :labels) || params[:labels]
    return nil if raw.nil?

    Array(raw).map(&:to_s)
  end

  def apply_labels
    list = label_list_param
    return if list.nil?

    @product.update_labels(list)
  end

  def attach_images
    signed_ids = Array(params.dig(:product, :images) || params[:images])
    signed_ids = signed_ids.reject { |sid| sid.respond_to?(:read) } # ignore raw files in this iteration
    return if signed_ids.empty?

    signed_ids.each do |signed_id|
      blob = ActiveStorage::Blob.find_signed(signed_id)
      @product.images.attach(blob) if blob.present?
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      next
    end
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
