# == Schema Information
#
# Table name: carousel_upload_batches
#
#  id                :uuid             not null, primary key
#  caption           :text
#  channel_type      :string           not null
#  container_ids     :jsonb            not null
#  created_by        :uuid             not null
#  error_message     :text
#  external_post_ids :jsonb            not null
#  platforms         :string           default([]), not null, is an Array
#  status            :string           default("collecting"), not null
#  total_cards       :integer          not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  channel_id        :string           not null
#
# Indexes
#
#  index_carousel_upload_batches_on_created_by  (created_by)
#  index_carousel_upload_batches_on_status      (status)
#
class CarouselUploadBatch < ApplicationRecord
  self.table_name = 'carousel_upload_batches'

  STATUSES = %w[collecting publishing published failed abandoned].freeze
  PLATFORMS = %w[instagram facebook].freeze

  belongs_to :creator, class_name: 'User', foreign_key: :created_by, inverse_of: false

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :total_cards, numericality: { only_integer: true, greater_than_or_equal_to: 2, less_than_or_equal_to: 10 }
  validate :platforms_are_known

  scope :stale_collecting, -> { where(status: 'collecting').where('updated_at < ?', 1.hour.ago) }

  # Um lote 'collecting' parado há mais de 1h normalmente foi mesmo
  # abandonado pelo usuário (fechou o modal no meio do upload dos cards) —
  # mas se ele já está completo (todos os cards prontos) e só não foi
  # publicado ainda por alguma demora do Sidekiq, reenfileiramos em vez de
  # descartar um carrossel pronto pra ir ao ar.
  def self.cleanup_abandoned!
    stale_collecting.find_each do |batch|
      if batch.complete?
        GestorPosts::CarouselPublishJob.perform_later(batch.id)
      else
        batch.mark_abandoned!
      end
    end
  end

  def append_container!(platform, container_id)
    with_lock do
      ids = container_ids.deep_dup
      ids[platform.to_s] = (ids[platform.to_s] || []) + [container_id]
      update!(container_ids: ids)
    end
  end

  def cards_for(platform)
    container_ids[platform.to_s] || []
  end

  def complete?
    platforms.present? && platforms.all? { |p| cards_for(p).size >= total_cards }
  end

  def mark_publishing!
    update!(status: 'publishing')
  end

  def mark_platform_published!(platform, external_id)
    update!(external_post_ids: external_post_ids.merge(platform.to_s => external_id))
  end

  def mark_published!
    update!(status: 'published', error_message: nil)
  end

  def mark_failed!(error)
    update!(status: 'failed', error_message: error.to_s)
  end

  def mark_abandoned!
    update!(status: 'abandoned')
  end

  private

  def platforms_are_known
    return if (platforms.to_a - PLATFORMS).empty?

    errors.add(:platforms, 'contém uma plataforma desconhecida')
  end
end
