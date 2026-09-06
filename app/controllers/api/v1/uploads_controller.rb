class Api::V1::UploadsController < Api::V1::BaseController
  before_action :check_upload_permission!

  def create
    result = if params[:attachment].present?
               create_from_file
             elsif params[:external_url].present?
               create_from_url
             else
               error_response(
                 ApiErrorCodes::MISSING_REQUIRED_FIELD,
                 'No file or URL provided'
               )
               return
             end

    if result.is_a?(ActiveStorage::Blob)
      success_response(
        data: {
          file_url: url_for(result),
          blob_key: result.key,
          blob_id: result.id
        },
        message: 'File uploaded successfully'
      )
    end
  end

  private

  # Uploads são usados tanto para anexos de conversa quanto para mídia de
  # produtos (imagens/vídeos), por isso aceitamos qualquer uma das permissões.
  def check_upload_permission!
    return if Current.service_authenticated
    return unless Current.user

    allowed = has_user_permission?(Current.user.id, 'conversations.attachments') ||
              has_user_permission?(Current.user.id, 'products.update')
    render_permission_denied unless allowed
  end

  def create_from_file
    attachment = params[:attachment]
    create_and_save_blob(attachment.tempfile, attachment.original_filename, attachment.content_type)
  end

  def create_from_url
    uri = parse_uri(params[:external_url])
    return if performed?

    fetch_and_process_file_from_uri(uri)
  end

  def parse_uri(url)
    uri = URI.parse(url)
    validate_uri(uri)
    uri
  rescue URI::InvalidURIError, SocketError
    error_response(
      ApiErrorCodes::INVALID_PARAMETER,
      'Invalid URL provided'
    )
    nil
  end

  def validate_uri(uri)
    raise URI::InvalidURIError unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  end

  def fetch_and_process_file_from_uri(uri)
    uri.open do |file|
      create_and_save_blob(file, File.basename(uri.path), file.content_type)
    end
  rescue OpenURI::HTTPError => e
    error_response(
      ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
      "Failed to fetch file from URL: #{e.message}"
    )
  rescue SocketError
    error_response(
      ApiErrorCodes::INVALID_PARAMETER,
      'Invalid URL provided'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      'An unexpected error occurred'
    )
  end

  def create_and_save_blob(io, filename, content_type)
    ActiveStorage::Blob.create_and_upload!(
      io: io,
      filename: filename,
      content_type: content_type
    )
  end

end
