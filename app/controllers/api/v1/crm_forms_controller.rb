# frozen_string_literal: true

# Admin CRUD for lead-capture forms (B14.01). Authenticated + permission-gated
# via the evo-auth-service catalog (crm_forms.{read,create,update,delete}).
class Api::V1::CrmFormsController < Api::V1::BaseController
  require_permissions({
                        index: 'crm_forms.read',
                        show: 'crm_forms.read',
                        leads: 'crm_forms.read',
                        create: 'crm_forms.create',
                        update: 'crm_forms.update',
                        destroy: 'crm_forms.delete'
                      })

  before_action :fetch_crm_form, only: [:show, :update, :destroy, :leads]

  def index
    scope = CrmForm.order(created_at: :desc)

    if params[:search].present?
      q = "%#{params[:search].strip}%"
      scope = scope.where('crm_forms.name ILIKE :q OR crm_forms.title ILIKE :q OR crm_forms.slug ILIKE :q', q: q)
    end

    scope = scope.where(published: ActiveModel::Type::Boolean.new.cast(params[:published])) if params[:published].present?

    page = params[:page].presence || 1
    per_page = params[:pageSize].presence || params[:per_page].presence || 20
    @crm_forms = scope.page(page).per(per_page)

    counts = CrmForm.lead_counts_by_slug(@crm_forms.map(&:slug))

    paginated_response(
      data: @crm_forms.map { |form| CrmFormSerializer.serialize(form, leads_count: counts[form.slug] || 0) },
      collection: @crm_forms,
      message: 'Forms retrieved successfully'
    )
  end

  def show
    success_response(
      data: CrmFormSerializer.serialize(@crm_form, leads_count: @crm_form.captured_leads.count),
      message: 'Form retrieved successfully'
    )
  end

  # GET /api/v1/crm_forms/:id/leads — leads captured by this form (B14.07).
  def leads
    items = @crm_form.captured_leads
                     .includes(:contact, :pipeline, :pipeline_stage)
                     .order(created_at: :desc)
                     .limit(200)

    success_response(
      data: items.map { |item| serialize_lead(item) },
      meta: { count: @crm_form.captured_leads.count },
      message: 'Leads retrieved successfully'
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

  def serialize_lead(item)
    {
      id: item.id,
      contact: item.contact && { id: item.contact.id, name: item.contact.name, email: item.contact.email },
      pipeline_id: item.pipeline_id,
      pipeline_stage_id: item.pipeline_stage_id,
      created_at: item.created_at&.iso8601
    }
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
