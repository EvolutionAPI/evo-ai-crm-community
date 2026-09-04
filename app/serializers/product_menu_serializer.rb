# frozen_string_literal: true

# Public-facing serialization of a Product for the digital menu page —
# only what an anonymous visitor needs to see. Deliberately omits internal
# fields (cost_price, supplier, stock, sku, ML fields, etc.) present in
# ProductSerializer.
module ProductMenuSerializer
  extend self

  def serialize(product)
    image = product.serialized_media.find { |m| m[:kind] == 'image' }

    {
      id: product.id,
      name: product.name,
      description: product.description,
      price: product.default_price.to_f,
      currency: product.currency,
      image_url: image && image[:url]
    }
  end

  def serialize_collection(products)
    products.map { |p| serialize(p) }
  end
end
