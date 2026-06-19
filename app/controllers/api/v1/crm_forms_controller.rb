# frozen_string_literal: true

# Admin CRUD for lead-capture forms (B14.01). Authenticated + permission-gated
# via the evo-auth-service catalog (crm_forms.{read,create,update,delete}).
class Api::V1::CrmFormsController < Api::V1::BaseController
  require_permissions({
                        index: 'crm_forms.read',
                        show: 'crm_forms.read',
                        create: 'crm_forms.create',
                        update: 'crm_forms.update',
                        destroy: 'crm_forms.delete'
                      })

  before_action :fetch_crm_form, only: [:show, :update, :destroy]

  def index
    @crm_forms = CrmForm.order(created_at: :desc)

    success_response(
      data: CrmFormSerializer.serialize_collection(@crm_forms),
      message: 'Forms retrieved successfully'
    )
  end

  def show
    success_response(
      data: CrmFormSerializer.serialize(@crm_form),
      message: 'Form retrieved successfully'
    )
  end

  def create
    @crm_form = CrmForm.new(crm_form_params)

    if @crm_form.save
      success_response(
        data: CrmFormSerializer.serialize(@crm_form),
        message: 'Form created successfully',
        status: :created
      )
    else
      validation_error(@crm_form)
    end
  end

  def update
    if @crm_form.update(crm_form_params)
      success_response(
        data: CrmFormSerializer.serialize(@crm_form),
        message: 'Form updated successfully'
      )
    else
      validation_error(@crm_form)
    end
  end

  def destroy
    @crm_form.destroy
    success_response(
      data: { id: @crm_form.id },
      message: 'Form deleted successfully'
    )
  end

  private

  def fetch_crm_form
    @crm_form = CrmForm.find(params[:id])
  end

  def crm_form_params
    params.require(:crm_form).permit(
      :name, :title, :description, :published,
      :default_pipeline_id, :default_stage_id,
      appearance: {},
      fields: [:key, :label, :type, :required, :placeholder, :maps_to, :maps_to_key, { options: [] }],
      routing_rules: [:field, :op, :value, :pipeline_id, :stage_id]
    )
  end

  def validation_error(record)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: record.errors.full_messages,
      status: :unprocessable_entity
    )
  end
end
