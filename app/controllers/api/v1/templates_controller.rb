# frozen_string_literal: true

class Api::V1::TemplatesController < Api::V1::BaseController
  require_permissions({
    export: 'templates.export',
    import: 'templates.import',
    exportable_inventory: 'templates.export'
  })

  # GET /api/v1/templates/exportable_inventory
  # Returns a category-grouped inventory for the export wizard.
  def exportable_inventory
    success_response(data: Templates::ExportService.exportable_inventory(current_user: Current.user))
  rescue StandardError => e
    Rails.logger.error("Templates#exportable_inventory: #{e.class}: #{e.message}")
    error_response(ApiErrorCodes::TEMPLATE_EXPORT_FAILED, e.message, status: :unprocessable_entity)
  end

  # POST /api/v1/templates/export
  # Body: { template_name, description, author, selection: { <category>: { all|ids } } }
  # Response: application/zip download.
  def export
    result = Templates::ExportService.new(
      selection: params[:selection]&.to_unsafe_h || {},
      template_name: params[:template_name],
      description: params[:description],
      author: params[:author],
      current_user: Current.user
    ).perform

    response.headers['Content-Disposition'] = "attachment; filename=\"#{result.filename}\""
    send_data result.io.string, type: 'application/zip', filename: result.filename
  rescue StandardError => e
    Rails.logger.error("Templates#export: #{e.class}: #{e.message}")
    error_response(ApiErrorCodes::TEMPLATE_EXPORT_FAILED, e.message, status: :unprocessable_entity)
  end

  # POST /api/v1/templates/import
  # Multipart with `bundle_file`.
  # Response: JSON { manifest, items, warnings }
  def import
    file = params[:bundle_file]
    return error_response(ApiErrorCodes::TEMPLATE_INVALID_BUNDLE, 'bundle_file is required', status: :bad_request) if file.blank?

    report = Templates::ImportService.new(
      uploaded_file: file.tempfile,
      current_user: Current.user
    ).perform

    success_response(data: report.to_h, message: 'Template imported')
  rescue Templates::BundleReader::FileTooLargeError => e
    error_response(ApiErrorCodes::TEMPLATE_FILE_TOO_LARGE, e.message, status: :payload_too_large)
  rescue Templates::BundleReader::UnsupportedSchemaError => e
    error_response(ApiErrorCodes::TEMPLATE_UNSUPPORTED_SCHEMA, e.message, status: :unprocessable_entity)
  rescue Templates::BundleReader::InvalidBundleError => e
    error_response(ApiErrorCodes::TEMPLATE_INVALID_BUNDLE, e.message, status: :unprocessable_entity)
  rescue ActiveRecord::RecordInvalid => e
    error_response(ApiErrorCodes::TEMPLATE_IMPORT_FAILED, e.message, status: :unprocessable_entity)
  rescue StandardError => e
    Rails.logger.error("Templates#import: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    error_response(ApiErrorCodes::TEMPLATE_IMPORT_FAILED, e.message, status: :unprocessable_entity)
  end
end
