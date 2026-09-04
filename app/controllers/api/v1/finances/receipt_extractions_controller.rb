class Api::V1::Finances::ReceiptExtractionsController < Api::V1::BaseController
  MAX_FILE_SIZE = 10.megabytes

  def create
    file = params[:attachment]
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Nenhuma imagem enviada') unless file.present?
    return error_response(ApiErrorCodes::INVALID_PARAMETER, 'Arquivo muito grande (máximo 10MB)') if file.size > MAX_FILE_SIZE

    bytes = file.read
    file.rewind

    blob = ActiveStorage::Blob.create_and_upload!(
      io: file.tempfile,
      filename: file.original_filename,
      content_type: file.content_type
    )

    result = Finances::ReceiptExtractionService.new(
      image_bytes: bytes,
      content_type: file.content_type,
      provider: params[:provider]
    ).call

    if result[:success]
      success_response(data: result[:data].merge(receipt_url: url_for(blob), provider: result[:provider]))
    else
      error_response(ApiErrorCodes::AI_SERVICE_ERROR, result[:error])
    end
  end

  # GET /api/v1/finances/receipt_extractions/providers
  # Reporta quais provedores de IA (OpenAI/Gemini) estão configurados, para a
  # tela de Notas & Recibos mostrar quais opções o usuário pode escolher.
  def providers
    success_response(data: Finances::AiProviderKeys.status)
  end
end
