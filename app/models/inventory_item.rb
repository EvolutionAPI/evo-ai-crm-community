# == Schema Information
#
# Table name: inventory_items
#
#  id           :uuid             not null, primary key
#  min_quantity :decimal(10, 2)   default(5.0), not null
#  name         :string           not null
#  quantity     :decimal(10, 2)   default(0.0), not null
#  sku          :string
#  unit         :string           default("un")
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_inventory_items_on_sku  (sku) UNIQUE
#
class InventoryItem < ApplicationRecord
  validates :name, presence: true, length: { maximum: 255 }
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :min_quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :sku, uniqueness: true, allow_blank: true
end
