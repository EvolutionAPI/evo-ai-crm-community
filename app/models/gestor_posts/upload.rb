# == Schema Information
#
# Table name: gestor_posts_uploads
#
#  id                :uuid             not null, primary key
#  caption           :text
#  content_type      :string           not null
#  created_by        :uuid             not null
#  error_message     :text
#  external_post_ids :jsonb            not null
#  platforms         :string           default([]), not null, is an Array
#  status            :string           default("pending"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#
#  index_gestor_posts_uploads_on_created_by  (created_by)
#  index_gestor_posts_uploads_on_status      (status)
#
module GestorPosts
  # Uma publicação (mídia única — feed/stories/reels) submetida pela tela
  # "Gestor de Posts". Substitui o base64-em-JSON do fluxo n8n por um upload
  # de verdade via ActiveStorage; a URL pública temporária pra Graph API é
  # resolvida com BlobUrlOptions.outbound_media_url, não Dropbox.
  class Upload < ApplicationRecord
    self.table_name = 'gestor_posts_uploads'

    has_one_attached :media
    belongs_to :creator, class_name: 'User', foreign_key: :created_by, inverse_of: false

    CONTENT_TYPES = %w[feed stories reels].freeze
    STATUSES = %w[pending publishing published failed].freeze
    PLATFORMS = %w[instagram facebook].freeze

    validates :content_type, presence: true, inclusion: { in: CONTENT_TYPES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validate :platforms_are_known

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

    def public_media_url
      return nil unless media.attached?

      BlobUrlOptions.outbound_media_url(media.blob)
    end

    private

    def platforms_are_known
      return if (platforms.to_a - PLATFORMS).empty?

      errors.add(:platforms, 'contém uma plataforma desconhecida')
    end
  end
end
