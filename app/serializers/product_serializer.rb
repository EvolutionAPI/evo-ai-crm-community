# frozen_string_literal: true

# ProductSerializer - Optimized serialization for Product resources.
#
# Plain Ruby module for Oj direct serialization, matching the convention
# used by CannedResponseSerializer / AutomationRuleSerializer in this app.
#
# Usage:
#   ProductSerializer.serialize(@product)
#   ProductSerializer.serialize_collection(@products)
module ProductSerializer
  extend self

  def serialize(product)
    {
      id: product.id,
      name: product.name,
      slug: product.slug,
      kind: product.kind,
      item_type: product.item_type,
      description: product.description,
      sku: product.sku,
      default_price: product.default_price.to_f,
      cost_price: product.cost_price&.to_f,
      profit: product.profit.to_f,
      currency: product.currency,
      purchase_url: product.purchase_url,
      status: product.status,
      stock_quantity: product.stock_quantity,
      supplier: product.supplier,
      material: product.material,
      color: product.color,
      size: product.size,
      weight_kg: product.weight_kg&.to_f,
      height_cm: product.height_cm&.to_f,
      width_cm: product.width_cm&.to_f,
      length_cm: product.length_cm&.to_f,
      ml_category: product.ml_category,
      ml_buying_model: product.ml_buying_model,
      ml_listing_type: product.ml_listing_type,
      ml_condition: product.ml_condition,
      brand: product.brand,
      model: product.model,
      compatible_brands: product.compatible_brands,
      accessory_type: product.accessory_type,
      anatel_number: product.anatel_number,
      publish_ml: product.publish_ml,
      metadata: product.metadata || {},
      labels: product.respond_to?(:label_list) ? product.label_list : [],
      category_id: product.product_category&.id,
      category_name: product.product_category&.name,
      ingredients: serialize_ingredients(product),
      media: product.serialized_media,
      variants: serialize_variants(product.variants),
      images: serialize_images(product),
      created_at: product.created_at&.iso8601,
      updated_at: product.updated_at&.iso8601
    }
  end

  def serialize_collection(products)
    return [] unless products

    products.map { |product| serialize(product) }
  end

  private

  def serialize_variants(variants)
    return [] unless variants

    variants.map { |variant| ProductVariantSerializer.serialize(variant) }
  end

  def serialize_ingredients(product)
    return [] unless product.respond_to?(:product_ingredients)

    product.product_ingredients.map do |line|
      {
        id: line.id,
        ingredient_product_id: line.ingredient_product_id,
        name: line.ingredient_product&.name,
        quantity: line.quantity.to_f,
        unit: line.unit
      }
    end
  end

  def serialize_images(product)
    return [] unless product.respond_to?(:images) && product.images.attached?

    product.images.map do |image|
      {
        id: image.id,
        url: Rails.application.routes.url_helpers.rails_blob_url(image, only_path: true),
        content_type: image.content_type,
        filename: image.filename.to_s,
        byte_size: image.byte_size
      }
    end
  end
end
