# == Schema Information
#
# Table name: user_tours
#
#  id           :bigint           not null, primary key
#  completed_at :datetime
#  status       :string           default("completed"), not null
#  tour_key     :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :uuid             not null
#
# Indexes
#
#  index_user_tours_on_user_id               (user_id)
#  index_user_tours_on_user_id_and_tour_key  (user_id,tour_key) UNIQUE
#
class UserTour < ApplicationRecord
  belongs_to :user

  STATUSES = %w[pending completed skipped].freeze

  validates :tour_key, presence: true, uniqueness: { scope: :user_id }
  validates :status, inclusion: { in: STATUSES }
end
