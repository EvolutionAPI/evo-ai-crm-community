class EvolutionGoHealthMonitor < ApplicationRecord
  STATES = %w[unknown healthy degraded].freeze

  belongs_to :observed_channel, class_name: 'Channel::Whatsapp'
  belongs_to :notification_channel, class_name: 'Channel::Whatsapp'

  validates :recipient_number, presence: true, format: { with: /\A\+?\d{10,15}\z/ }
  validates :failure_threshold, :recovery_threshold, numericality: { only_integer: true, greater_than: 0 }
  validates :cooldown_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :last_state, inclusion: { in: STATES }
  validate :evolution_go_channels

  scope :enabled, -> { where(enabled: true) }

  private

  def evolution_go_channels
    errors.add(:observed_channel, 'must use Evolution Go') unless observed_channel&.provider == 'evolution_go'
    errors.add(:notification_channel, 'must use Evolution Go') unless notification_channel&.provider == 'evolution_go'
  end
end
