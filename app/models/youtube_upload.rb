# == Schema Information
#
# Table name: youtube_uploads
#
#  id                :uuid             not null, primary key
#  created_by        :uuid             not null
#  description       :text
#  error_message     :text
#  privacy_status    :string           default("unlisted"), not null
#  status            :string           default("pending"), not null
#  title             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  external_video_id :string
#
# Indexes
#
#  index_youtube_uploads_on_created_by  (created_by)
#  index_youtube_uploads_on_status      (status)
#
# Um vídeo do "Gestor de Posts" enviado pro canal do YouTube conectado
# (Configurações > Integrações > Google Login, escopo youtube.upload). O
# upload é lento, então roda em background — ver
# GestorPosts::YoutubeUploadJob e Youtube::UploadService.
class YoutubeUpload < ApplicationRecord
  self.table_name = 'youtube_uploads'

  has_one_attached :video
  belongs_to :creator, class_name: 'User', foreign_key: :created_by, inverse_of: false

  PRIVACY_STATUSES = %w[public unlisted private].freeze
  STATUSES = %w[pending uploading published failed].freeze

  validates :title, presence: true
  validates :privacy_status, presence: true, inclusion: { in: PRIVACY_STATUSES }
  validates :status, presence: true, inclusion: { in: STATUSES }

  def mark_uploading!
    update!(status: 'uploading')
  end

  def mark_published!(video_id)
    update!(status: 'published', external_video_id: video_id, error_message: nil)
  end

  def mark_failed!(error)
    update!(status: 'failed', error_message: error.to_s)
  end
end
