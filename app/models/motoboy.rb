class Motoboy < ApplicationRecord
  STATUSES = %w[disponivel em_entrega offline].freeze
  VEHICLE_TYPES = %w[moto bike carro].freeze

  has_many :motoboy_deliveries, dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :vehicle_type, inclusion: { in: VEHICLE_TYPES }

  scope :active_only, -> { where(active: true) }
end
