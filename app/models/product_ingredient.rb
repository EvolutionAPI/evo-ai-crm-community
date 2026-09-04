# frozen_string_literal: true

# == Schema Information
#
# Table name: product_ingredients
#
#  id                    :uuid             not null, primary key
#  quantity              :decimal(14, 3)   default(0.0), not null
#  unit                  :string           default("un"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  ingredient_product_id :uuid             not null
#  product_id            :uuid             not null
#
# Indexes
#
#  idx_product_ingredients_unique                      (product_id,ingredient_product_id) UNIQUE
#  index_product_ingredients_on_ingredient_product_id  (ingredient_product_id)
#  index_product_ingredients_on_product_id             (product_id)
#
# Foreign Keys
#
#  fk_rails_...  (ingredient_product_id => products.id) ON DELETE => cascade
#  fk_rails_...  (product_id => products.id) ON DELETE => cascade
#
class ProductIngredient < ApplicationRecord
  belongs_to :product
  belongs_to :ingredient_product, class_name: 'Product'

  validates :quantity, numericality: { greater_than: 0 }, presence: true
  validates :unit, presence: true, length: { maximum: 20 }
  validates :ingredient_product_id, uniqueness: { scope: :product_id }
end
