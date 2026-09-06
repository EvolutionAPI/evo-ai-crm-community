module GestorPosts
  # Upload de vídeo pro YouTube é lento (protocolo resumível + PUT do
  # binário inteiro), então roda em background — ver Youtube::UploadService.
  class YoutubeUploadJob < ApplicationJob
    queue_as :default

    def perform(youtube_upload_id)
      upload = YoutubeUpload.find_by(id: youtube_upload_id)
      return unless upload

      upload.mark_uploading!

      begin
        Youtube::UploadService.new(upload: upload).publish!
      rescue Youtube::UploadService::Error => e
        Rails.logger.error("GestorPosts::YoutubeUploadJob: #{e.message}")
        upload.mark_failed!(e.message)
      end
    end
  end
end
