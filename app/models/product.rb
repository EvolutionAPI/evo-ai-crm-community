# == Schema Information
#
# Table name: products
#
#  id             :uuid             not null, primary key
#  currency       :string(3)        default("BRL"), not null
#  default_price  :decimal(10, 2)   default(0.0), not null
#  description    :text
#  kind           :string(20)       default("physical"), not null
#  metadata       :jsonb            not null
#  name           :string(255)      not null
#  purchase_url   :string(2048)
#  sku            :string(100)
#  slug           :string(255)
#  status         :string(20)       default("active"), not null
#  stock_quantity :integer
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
# Indexes
#
#  index_products_on_kind      (kind)
#  index_products_on_metadata  (metadata) USING gin
#  index_products_on_sku       (sku) UNIQUE WHERE (sku IS NOT NULL)
#  index_products_on_status    (status)
#
class Product < ApplicationRecord
  include Labelable

  KINDS    = %w[physical digital].freeze
  STATUSES = %w[active inactive draft].freeze
  ALLOWED_CURRENCIES = %w[BRL USD EUR].freeze
  URL_REGEXP = %r{\Ahttps?://[^\s]+\z}.freeze

  has_many_attached :images

  has_many :variants,
           -> { order(:position, :name) },
           class_name: 'ProductVariant',
           dependent: :destroy
  accepts_nested_attributes_for :variants, allow_destroy: true, reject_if: :all_blank

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
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :default_price, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true, inclusion: { in: ALLOWED_CURRENCIES }
  validates :sku, uniqueness: true, allow_blank: true
  validates :stock_quantity, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validates :purchase_url, format: { with: URL_REGEXP }, allow_blank: true

  scope :active,   -> { where(status: 'active') }
  scope :by_kind,  ->(kind) { where(kind: kind) if kind.present? }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :order_by_recent, -> { order(created_at: :desc) }

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
