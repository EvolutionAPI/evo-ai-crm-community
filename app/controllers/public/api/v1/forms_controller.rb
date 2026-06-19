# frozen_string_literal: true

# Anonymous, public lead-capture form endpoint (B14.01).
#
# Inherits directly from PublicController (NOT Public::Api::V1::BaseController)
# so it is reachable WITHOUT an API key: the form is resolved from its public
# slug. Only published forms respond; everything else 404s without leaking.
class Public::Api::V1::FormsController < PublicController
  before_action :set_form

  # GET /public/api/v1/forms/:slug — config for rendering the public page.
  def show
    render json: { success: true, data: CrmFormPublicSerializer.serialize(@form) }
  end

  # POST /public/api/v1/forms/:slug/submissions — anonymous lead submission.
  def create
    result = Public::Forms::SubmissionService.new(form: @form, params: submission_params).perform

    if result[:success]
      render json: {
        success: true,
        lead_id: result[:contact]&.id,
        deal_id: result[:pipeline_item]&.id,
        message: 'Lead created successfully'
      }, status: :created
    else
      errors = Array(result[:errors].presence || result[:error])
      render json: {
        success: false,
        error: errors.join(', '),
        details: errors
      }, status: :unprocessable_entity
    end
  end

  private

  def set_form
    @form = CrmForm.published.find_by(slug: params[:slug])
    return if @form

    render json: { success: false, error: 'Form not found' }, status: :not_found
  end

  # Permits an arbitrary set of field keys under :submission (forms are dynamic).
  def submission_params
    params.permit(submission: {})
  end
end
