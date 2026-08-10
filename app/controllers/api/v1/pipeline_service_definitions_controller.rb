class Api::V1::PipelineServiceDefinitionsController < Api::V1::BaseController
  require_permissions({
    index: 'pipelines.read',
    show: 'pipelines.read',
    create: 'pipelines.write',
    update: 'pipelines.write',
    destroy: 'pipelines.write'
  })

  before_action :set_pipeline
  before_action :set_service_definition, only: [:show, :update, :destroy]

  def index
    @service_definitions = @pipeline.pipeline_service_definitions.active.order(:name)

    success_response(
      data: PipelineServiceDefinitionSerializer.serialize_collection(@service_definitions),
      message: 'Service definitions retrieved successfully'
    )
  end

  def show
    success_response(
      data: PipelineServiceDefinitionSerializer.serialize(@service_definition),
      message: 'Service definition retrieved successfully'
    )
  end

  def create
    @service_definition = @pipeline.pipeline_service_definitions.new(
      service_definition_params
    )

    if @service_definition.save
      success_response(
        data: PipelineServiceDefinitionSerializer.serialize(@service_definition),
        message: 'Service definition created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @service_definition.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def update
    if @service_definition.update(service_definition_params)
      success_response(
        data: PipelineServiceDefinitionSerializer.serialize(@service_definition),
        message: 'Service definition updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @service_definition.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @service_definition.update!(active: false)
    head :no_content
  end

  private

  def set_pipeline
    @pipeline = Pipeline.find(params[:pipeline_id])
    authorize @pipeline, :view?
  end

  def set_service_definition
    @service_definition = @pipeline.pipeline_service_definitions.find(params[:id])
  end

  def service_definition_params
    params.require(:service_definition).permit(:name, :default_value, :currency, :description, :active)
  end
end
