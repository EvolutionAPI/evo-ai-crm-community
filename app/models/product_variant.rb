# == Schema Information
#
# Table name: product_variants
#
#  id              :uuid             not null, primary key
#  attributes_data :jsonb            not null
#  name            :string(255)      not null
#  position        :integer          default(0), not null
#  price_override  :decimal(10, 2)
#  sku             :string(100)
#  stock_quantity  :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  product_id      :uuid             not null
#
# Indexes
#
#  index_product_variants_on_attributes_data   (attributes_data) USING gin
#  index_product_variants_on_product_and_name  (product_id,name) UNIQUE
#  index_product_variants_on_product_id        (product_id)
#  index_product_variants_on_sku               (sku) UNIQUE WHERE (sku IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (product_id => products.id) ON DELETE => cascade
#
class ProductVariant < ApplicationRecord
  belongs_to :product

  has_many :pipeline_item_products, dependent: :restrict_with_error

  # Same partial-unique-index trap as Product: "" is not NULL, so two variants
  # without SKU would collide on index_product_variants_on_sku.
  before_validation { self.sku = nil if sku.blank? }

  validates :name, presence: true, length: { maximum: 255 }
  validates :name, uniqueness: { scope: :product_id, case_sensitive: false }
  validates :sku, uniqueness: true, allow_blank: true
  validates :price_override, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :stock_quantity, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true

  default_scope { order(:position, :name) }

  # Effective price: the variant's override when present, otherwise the
  # product's default price. Currency always inherits from the product.
  def effective_price
    price_override || product&.default_price
  end

  def effective_currency
    product&.currency
  end
end
