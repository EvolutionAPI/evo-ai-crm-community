class MotoboyDelivery < ApplicationRecord
  STATUSES = %w[atribuido a_caminho entregue cancelado].freeze
  PLATFORMS = %w[proprio ifood].freeze

  belongs_to :motoboy

  validates :order_external_id, presence: true, uniqueness: { scope: :platform }
  validates :platform, inclusion: { in: PLATFORMS }
  validates :status, inclusion: { in: STATUSES }
end
