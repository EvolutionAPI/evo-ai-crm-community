# == Schema Information
#
# Table name: products
#
#  id                :uuid             not null, primary key
#  accessory_type    :string(255)
#  anatel_number     :string(100)
#  brand             :string(255)
#  color             :string(100)
#  compatible_brands :string(500)
#  cost_price        :decimal(10, 2)
#  currency          :string(3)        default("BRL"), not null
#  default_price     :decimal(10, 2)   default(0.0), not null
#  description       :text
#  height_cm         :decimal(10, 2)
#  item_type         :string(20)       default("produto"), not null
#  kind              :string(20)       default("physical"), not null
#  length_cm         :decimal(10, 2)
#  material          :text
#  media             :jsonb            not null
#  metadata          :jsonb            not null
#  ml_buying_model   :string(100)
#  ml_category       :string(100)
#  ml_condition      :string(100)
#  ml_listing_type   :string(100)
#  model             :string(255)
#  name              :string(255)      not null
#  publish_ml        :boolean          default(FALSE), not null
#  purchase_url      :string(2048)
#  size              :string(100)
#  sku               :string(100)
#  slug              :string(255)
#  status            :string(20)       default("active"), not null
#  stock_quantity    :integer
#  supplier          :string(255)
#  weight_kg         :decimal(10, 3)
#  width_cm          :decimal(10, 2)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  category_id       :uuid
#
# Indexes
#
#  index_products_on_item_type  (item_type)
#  index_products_on_kind       (kind)
#  index_products_on_metadata   (metadata) USING gin
#  index_products_on_sku        (sku) UNIQUE WHERE (sku IS NOT NULL)
#  index_products_on_status     (status)
#  index_products_on_supplier   (supplier)
#
# Foreign Keys
#
#  fk_rails_...  (category_id => product_categories.id)
#
class Product < ApplicationRecord
  include Labelable

  KINDS    = %w[physical digital].freeze
  ITEM_TYPES = %w[produto produto_ml servico].freeze
  STATUSES = %w[active inactive draft].freeze
  ALLOWED_CURRENCIES = %w[BRL USD EUR].freeze
  URL_REGEXP = %r{\Ahttps?://[^\s]+\z}.freeze

  has_many_attached :images

  belongs_to :product_category, optional: true, foreign_key: :category_id

  has_many :variants,
           -> { order(:position, :name) },
           class_name: 'ProductVariant',
           dependent: :destroy
  accepts_nested_attributes_for :variants, allow_destroy: true, reject_if: :all_blank

  has_many :product_ingredients, -> { order(:created_at) }, dependent: :destroy
  has_many :ingredients,
           -> { order(:name) },
           through: :product_ingredients,
           source: :ingredient_product
  accepts_nested_attributes_for :product_ingredients,
                                allow_destroy: true,
                                reject_if: ->(a) { a['ingredient_product_id'].blank? }

  has_many :sold_as_ingredient,
           class_name: 'ProductIngredient',
           foreign_key: :ingredient_product_id,
           dependent: :destroy
  has_many :parent_products,
           -> { order(:name) },
           through: :sold_as_ingredient,
           source: :product

  has_many :ai_agent_products, dependent: :destroy
  has_many :pipeline_item_products, dependent: :restrict_with_error
  has_many :pipeline_items, through: :pipeline_item_products

  # Blank SKU must persist as NULL: the partial unique index (WHERE sku IS NOT NULL)
  # ignores NULLs, but "" is a real value — the second no-SKU product would raise
  # PG::UniqueViolation (409) on the ("",) key. Prepended so it runs before
  # ApplicationRecord's generic length guard, which would otherwise reject a
  # whitespace-only SKU over 255 chars that this is about to discard anyway.
  before_validation(prepend: true) { self.sku = nil if sku.blank? }

  validates :name, presence: true, length: { maximum: 255 }
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :item_type, presence: true, inclusion: { in: ITEM_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :default_price, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true, inclusion: { in: ALLOWED_CURRENCIES }
  validates :sku, uniqueness: true, allow_blank: true
  validates :stock_quantity, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validates :purchase_url, format: { with: URL_REGEXP }, allow_blank: true
  validates :cost_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :weight_kg, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :height_cm, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :width_cm, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :length_cm, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  class InsufficientStockError < StandardError
    attr_reader :product_name

    def initialize(product_name)
      @product_name = product_name
      super("Estoque insuficiente de #{product_name}")
    end
  end

  scope :active,   -> { where(status: 'active') }
  # Exclui insumos puros — produtos que só existem como ingrediente de outro
  # produto (ex.: "Alface", "Pão") e nunca são vendidos por conta própria (não
  # têm receita/ingredientes próprios). O catálogo não distingue isso por um
  # campo (item_type é sempre "produto" tanto pro insumo quanto pro item final),
  # então a regra é relacional: usado como ingrediente em algo + sem ingredientes
  # próprios = insumo puro. Usado pelo cardápio digital público (ver
  # Public::Api::V1::MenuController).
  scope :sellable, -> {
    ingredient_ids = ProductIngredient.distinct.pluck(:ingredient_product_id)
    compound_ids = ProductIngredient.distinct.pluck(:product_id)
    pure_ingredient_ids = ingredient_ids - compound_ids
    pure_ingredient_ids.present? ? where.not(id: pure_ingredient_ids) : all
  }
  scope :by_kind,  ->(kind) { where(kind: kind) if kind.present? }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :by_item_type, ->(item_type) {
    if item_type.present?
      types = item_type.is_a?(Array) ? item_type : item_type.to_s.split(',')
      where(item_type: types)
    end
  }
  scope :order_by_recent, -> { order(created_at: :desc) }

  # Profit (valor de venda - custo). Falls back to zero when no cost is set.
  def profit
    default_price.to_f - (cost_price.to_f || 0.0)
  end

  # Registra a venda de `quantity` unidades: baixa o estoque do próprio
  # produto (quando ele tem controle de estoque) e de cada insumo consumido.
  # Ex.: vender 1 Hambúrguer baixa Pão, Carne, Alface etc.
  # Retorna a lista de itens afetados [{ id, name, stock_quantity }].
  def sell!(quantity: 1)
    quantity = quantity.to_i
    raise ArgumentError, 'quantity must be positive' if quantity <= 0

    affected = []
    ActiveRecord::Base.transaction do
      if stock_quantity.present?
        if stock_quantity < quantity
          raise InsufficientStockError.new(name)
        end

        lock!
        update!(stock_quantity: stock_quantity - quantity)
        affected << { id: id, name: name, stock_quantity: stock_quantity }
      end

      product_ingredients.includes(:ingredient_product).each do |line|
        next if line.quantity.nil? || line.quantity <= 0

        ingredient = line.ingredient_product
        next unless ingredient.stock_quantity.present?

        needed = (line.quantity * quantity).round
        if ingredient.stock_quantity < needed
          raise InsufficientStockError.new(ingredient.name)
        end

        ingredient.lock!
        ingredient.update!(stock_quantity: ingredient.stock_quantity - needed)
        affected << { id: ingredient.id, name: ingredient.name, stock_quantity: ingredient.stock_quantity }
      end
    end
    affected
  end

  # Media items (imagens/vídeos): lista extras persistida em `media` (jsonb)
  # incluindo itens legados anexados via Active Storage (has_many_attached).
  def serialized_media
    list = []
    if respond_to?(:images) && images.attached?
      images.each do |image|
        list << {
          id: "img-#{image.id}",
          kind: 'image',
          source: 'upload',
          url: Rails.application.routes.url_helpers.rails_blob_url(image, only_path: true)
        }
      end
    end
    Array(media).each_with_index do |item, index|
      next unless item.is_a?(Hash)

      list << {
        id: item['id'].presence || "media-#{index}",
        kind: item['kind'] == 'video' ? 'video' : 'image',
        source: item['source'] || 'url',
        url: item['url'].to_s
      }
    end
    list
  end

  # Returns the effective unit price for a given variant. When the variant
  # has a `price_override` we use it; otherwise we fall back to the
  # product's `default_price`. Pass `nil` to get the base price.
  def effective_price_for(variant: nil)
    variant&.price_override || default_price
  end

  # Lightweight payload used when injecting the catalog into the AI agent
  # system prompt. Keep this small — the entire collection ends up inside
  # a single LLM context window.
  def to_prompt_summary
    {
      id: id,
      name: name,
      kind: kind,
      default_price: default_price.to_f,
      currency: currency,
      purchase_url: purchase_url,
      description: description.to_s.truncate(280)
    }
  end
end
