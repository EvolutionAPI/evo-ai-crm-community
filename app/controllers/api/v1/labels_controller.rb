class Api::V1::LabelsController < Api::V1::BaseController
  # CRM-190: index/show were ungated while `labels.read` was already granted by
  # every seeded role, so the key enforced nothing — any authenticated user could
  # list every label. Reading the shared label catalog is attendance, but it is
  # still gated by its own key.
  require_permissions({
    index: 'labels.read',
    show: 'labels.read',
    create: 'labels.create',
    update: 'labels.update',
    destroy: 'labels.delete'
  })

  before_action :fetch_label, except: [:index, :create]

  def index
    @labels = Label.all
    
    apply_pagination
    
    paginated_response(
      data: LabelSerializer.serialize_collection(@labels),
      collection: @labels,
      message: 'Labels retrieved successfully'
    )
  end

  def show
    success_response(
      data: LabelSerializer.serialize(@label),
      message: 'Label retrieved successfully'
    )
  end

  def create
    @label = Label.all.new(permitted_params)
    
    if @label.save
      success_response(
        data: LabelSerializer.serialize(@label),
        message: 'Label created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: format_validation_errors(@label.errors),
        status: :unprocessable_entity
      )
    end
  end

  def update
    if @label.update(permitted_params)
      success_response(
        data: LabelSerializer.serialize(@label),
        message: 'Label updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: format_validation_errors(@label.errors),
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    deleted_id = @label.id
    ActiveRecord::Base.transaction do
      Labels::DeleteService.new(label_title: @label.title).perform
      @label.destroy!
    end
    success_response(
      data: { id: deleted_id },
      message: 'Label deleted successfully'
    )
  end

  private

  def fetch_label
    @label = Label.all.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::LABEL_NOT_FOUND,
      "Label with id #{params[:id]} not found",
      status: :not_found
    )
  end

  def permitted_params
    params.require(:label).permit(:title, :description, :color, :show_on_sidebar)
  end
end
