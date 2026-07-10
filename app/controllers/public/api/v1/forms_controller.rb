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

  # Resolve the form by its UUID id OR its slug. The public link now uses the id
  # (globally unique, no cross-tenant slug collision), but slug is still accepted so
  # links shared before this change keep working. The route param is :slug for
  # backwards compatibility; it may carry either value.
  def set_form
    key = params[:slug].to_s
    scope = CrmForm.published
    @form = uuid?(key) ? scope.find_by(id: key) : scope.find_by(slug: key)
    # Fall back to the other lookup so an id-shaped slug (or vice-versa) still resolves.
    @form ||= scope.find_by(slug: key)
    return if @form

    render json: { success: false, error: 'Form not found' }, status: :not_found
  end

  def uuid?(value)
    value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  # Permits an arbitrary set of field keys under :submission (forms are dynamic).
  def submission_params
    params.permit(submission: {})
  end
end
