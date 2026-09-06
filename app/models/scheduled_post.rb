# == Schema Information
#
# Table name: scheduled_posts
#
#  id                :uuid             not null, primary key
#  caption           :text
#  channel_type      :string           not null
#  content_type      :string           not null
#  created_by        :uuid             not null
#  error_message     :text
#  external_post_ids :jsonb            not null
#  max_retries       :integer          default(3), not null
#  platforms         :string           default([]), not null, is an Array
#  retry_count       :integer          default(0), not null
#  scheduled_for     :datetime         not null
#  status            :string           default("scheduled"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  channel_id        :string           not null
#
# Indexes
#
#  index_scheduled_posts_on_created_by     (created_by)
#  index_scheduled_posts_on_scheduled_for  (scheduled_for)
#  index_scheduled_posts_on_status         (status)
#
class ScheduledPost < ApplicationRecord
  self.table_name = 'scheduled_posts'

  has_one_attached :media
  belongs_to :creator, class_name: 'User', foreign_key: :created_by, inverse_of: false

  CONTENT_TYPES = %w[feed stories reels].freeze
  STATUSES = %w[scheduled executing completed failed cancelled].freeze
  PLATFORMS = %w[instagram facebook].freeze

  validates :content_type, presence: true, inclusion: { in: CONTENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :channel_type, :channel_id, presence: true
  validates :scheduled_for, presence: true
  validate :platforms_are_known
  validate :scheduled_for_cannot_be_in_past, on: :create

  scope :due, -> { where(status: 'scheduled').where('scheduled_for <= ?', Time.current) }
  scope :upcoming, -> { where(status: 'scheduled').where('scheduled_for > ?', Time.current) }
  scope :retriable, -> { where(status: 'failed').where('retry_count < max_retries') }
  scope :recent, -> { order(created_at: :desc) }

  def mark_as_executing!
    update!(status: 'executing')
  end

  def mark_as_completed!
    update!(status: 'completed', error_message: nil)
  end

  def mark_as_failed!(error)
    update!(status: 'failed', error_message: error.to_s, retry_count: retry_count + 1)
  end

  def mark_as_cancelled!
    update!(status: 'cancelled')
  end

  def mark_platform_published!(platform, external_id)
    update!(external_post_ids: external_post_ids.merge(platform.to_s => external_id))
  end

  def public_media_url
    return nil unless media.attached?

    BlobUrlOptions.outbound_media_url(media.blob)
  end

  def scheduled?
    status == 'scheduled'
  end

  def can_retry?
    status == 'failed' && retry_count < max_retries
  end

  def retry!
    raise 'Post não pode ser reenviado.' unless can_retry?

    update!(status: 'scheduled', scheduled_for: Time.current, error_message: nil)
  end

  private

  def platforms_are_known
    return if (platforms.to_a - PLATFORMS).empty?

    errors.add(:platforms, 'contém uma plataforma desconhecida')
  end

  def scheduled_for_cannot_be_in_past
    return unless scheduled_for.present? && scheduled_for < Time.current

    errors.add(:scheduled_for, 'não pode estar no passado')
  end
end
