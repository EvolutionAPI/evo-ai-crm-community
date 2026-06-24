class Api::V1::CannedResponsesController < Api::V1::BaseController # rubocop:disable Metrics/ClassLength
  include FileTypeHelper

  require_permissions({
                        index: 'canned_responses.read',
                        show: 'canned_responses.read',
                        create: 'canned_responses.create',
                        update: 'canned_responses.update',
                        destroy: 'canned_responses.delete'
                      })

  before_action :fetch_canned_response, only: [:show, :update, :destroy]

  MAX_ATTACHMENT_BYTES = 10.megabytes

  def index
    @canned_responses = canned_responses

    apply_pagination

    paginated_response(
      data: CannedResponseSerializer.serialize_collection(@canned_responses),
      collection: @canned_responses,
      message: 'Canned responses retrieved successfully'
    )
  end

  def show
    success_response(
      data: CannedResponseSerializer.serialize(@canned_response),
      message: 'Canned response retrieved successfully'
    )
  end

  def create
    return if reject_invalid_signed_ids
    return if reject_oversized_attachments

    @canned_response = CannedResponse.new(canned_response_params)

    if @canned_response.save
      attach_files if params[:attachments].present?
      success_response(
        data: CannedResponseSerializer.serialize(@canned_response),
        message: 'Canned response created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @canned_response.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def update
    return if reject_invalid_signed_ids
    return if reject_oversized_attachments

    if @canned_response.update(canned_response_params)
      detach_files if params[:remove_attachment_ids].present?
      attach_files if params[:attachments].present?
      success_response(
        data: CannedResponseSerializer.serialize(@canned_response),
        message: 'Canned response updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @canned_response.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @canned_response.destroy
    success_response(
      data: { id: @canned_response.id },
      message: 'Canned response deleted successfully'
    )
  end

  private

  def fetch_canned_response
    @canned_response = CannedResponse.find(params[:id])
  end

  def fetch_canned_responses
    @canned_responses = CannedResponse.all
  end

  def canned_response_params
    params.require(:canned_response).permit(:short_code, :content)
  end

  def attach_files
    normalized_attachments.each do |attachment_param|
      if attachment_param.is_a?(ActionController::Parameters) || attachment_param.is_a?(Hash)
        # Se for um hash com signed_id (direct upload)
        if attachment_param[:signed_id].present?
          attach_from_signed_id(attachment_param)
        elsif attachment_param[:file].present?
          # Se for um hash com file
          attach_from_file(attachment_param[:file])
        end
      elsif attachment_param.respond_to?(:read)
        # Se for um arquivo direto (FormData)
        attach_from_file(attachment_param)
      end
    end
  end

  # FormData pode vir como array ou como hash
  def normalized_attachments
    if params[:attachments].is_a?(Array)
      params[:attachments]
    elsif params[:attachments].is_a?(ActionController::Parameters)
      params[:attachments].values
    else
      [params[:attachments]].compact
    end
  end

  def reject_oversized_attachments
    return false if params[:attachments].blank?
    return false unless normalized_attachments.any? { |a| attachment_byte_size(a).to_i > MAX_ATTACHMENT_BYTES }

    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      "Attachment exceeds the maximum allowed size (#{MAX_ATTACHMENT_BYTES / 1.megabyte} MB)",
      status: :unprocessable_entity
    )
    true
  end

  # An invalid/expired signed_id resolves to a nil blob, which slips past the size
  # gate (nil byte_size) and then raises 500 on attach(nil). Reject it as 422 up front.
  def reject_invalid_signed_ids
    return false if params[:attachments].blank?

    has_invalid = normalized_attachments.any? do |attachment_param|
      next false unless attachment_param.is_a?(ActionController::Parameters) || attachment_param.is_a?(Hash)
      next false if attachment_param[:signed_id].blank?

      ActiveStorage::Blob.find_signed(attachment_param[:signed_id]).nil?
    end
    return false unless has_invalid

    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'One or more attachments reference an invalid or expired upload',
      status: :unprocessable_entity
    )
    true
  end

  def attachment_byte_size(attachment_param)
    if attachment_param.is_a?(ActionController::Parameters) || attachment_param.is_a?(Hash)
      if attachment_param[:signed_id].present?
        ActiveStorage::Blob.find_signed(attachment_param[:signed_id])&.byte_size
      elsif attachment_param[:file].respond_to?(:size)
        attachment_param[:file].size
      end
    elsif attachment_param.respond_to?(:size)
      attachment_param.size
    end
  end

  def attach_from_file(file)
    file_type = determine_file_type(file.content_type)

    attachment = @canned_response.attachments.build(
      file_type: file_type
    )

    attachment.file.attach(
      io: file,
      filename: file.original_filename,
      content_type: file.content_type
    )

    attachment.save!
  end

  def attach_from_signed_id(attachment_params)
    signed_id = attachment_params[:signed_id]
    file_type = file_type_by_signed_id(signed_id)

    attachment = @canned_response.attachments.build(
      file_type: file_type
    )

    attachment.file.attach(ActiveStorage::Blob.find_signed(signed_id))
    attachment.save!
  end

  def determine_file_type(content_type)
    return :image if image_file?(content_type)
    return :video if video_file?(content_type)
    return :audio if content_type&.include?('audio/')

    :file
  end

  def canned_responses
    scope = CannedResponse.includes(attachments: { file_attachment: :blob })

    if params[:search]
      scope
        .where('short_code ILIKE :search OR content ILIKE :search', search: "%#{params[:search]}%")
        .order_by_search(params[:search])
    else
      scope
    end
  end

  def detach_files
    ids = Array(params[:remove_attachment_ids]).reject(&:blank?)
    return if ids.empty?

    @canned_response.attachments.where(id: ids).destroy_all
    # Drop the now-stale in-memory association so the serialized response reflects the deletion.
    @canned_response.attachments.reload
  end
end
