# frozen_string_literal: true

# == Schema Information
#
# Table name: product_categories
#
#  id         :uuid             not null, primary key
#  name       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_product_categories_on_name  (name) UNIQUE
#
class ProductCategory < ApplicationRecord
  has_many :products, dependent: :nullify, foreign_key: :category_id

  validates :name, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 120 }

  scope :search, ->(term) { term.presence && where('name ILIKE ?', "%#{term}%") }
  scope :ordered, -> { order(:name) }
end
