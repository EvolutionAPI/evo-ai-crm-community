class Api::V1::CustomAttributeDefinitionsController < Api::V1::BaseController
  require_permissions({
    index: 'custom_attribute_definitions.read',
    show: 'custom_attribute_definitions.read',
    create: 'custom_attribute_definitions.write',
    update: 'custom_attribute_definitions.write',
    destroy: 'custom_attribute_definitions.delete'
  })
  include Api::V1::ResourceLimitsHelper

  before_action :fetch_custom_attributes_definitions, except: [:create]
  before_action :fetch_custom_attribute_definition, only: [:show, :update, :destroy]
  before_action :validate_custom_attribute_limit_for_creation, only: [:create]
  DEFAULT_ATTRIBUTE_MODEL = 'conversation_attribute'.freeze

  def index
    success_response(
      data: CustomAttributeDefinitionSerializer.serialize_collection(@custom_attribute_definitions),
      message: 'Custom attribute definitions retrieved successfully'
    )
  end

  def show
    success_response(
      data: CustomAttributeDefinitionSerializer.serialize(@custom_attribute_definition),
      message: 'Custom attribute definition retrieved successfully'
    )
  end

  def create
    @custom_attribute_definition = CustomAttributeDefinition.new(permitted_payload)
    
    if @custom_attribute_definition.save
      success_response(
        data: CustomAttributeDefinitionSerializer.serialize(@custom_attribute_definition),
        message: 'Custom attribute definition created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @custom_attribute_definition.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def update
    if @custom_attribute_definition.update(permitted_payload)
      success_response(
        data: CustomAttributeDefinitionSerializer.serialize(@custom_attribute_definition),
        message: 'Custom attribute definition updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @custom_attribute_definition.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @custom_attribute_definition.destroy
    success_response(
      data: { id: @custom_attribute_definition.id },
      message: 'Custom attribute definition deleted successfully'
    )
  end

  private

  def fetch_custom_attributes_definitions
    @custom_attribute_definitions = CustomAttributeDefinition.with_attribute_model(permitted_params[:attribute_model])
  end

  def fetch_custom_attribute_definition
    @custom_attribute_definition = CustomAttributeDefinition.find(permitted_params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::CUSTOM_ATTRIBUTE_NOT_FOUND,
      "Custom attribute definition with id #{permitted_params[:id]} not found",
      status: :not_found
    )
  end

  def permitted_payload
    params.require(:custom_attribute_definition).permit(
      :attribute_display_name,
      :attribute_description,
      :attribute_display_type,
      :attribute_key,
      :attribute_model,
      :regex_pattern,
      :regex_cue,
      attribute_values: []
    )
  end

  def permitted_params
    params.permit(:id, :filter_type, :attribute_model)
  end

  def validate_custom_attribute_limit_for_creation
    attribute_model = permitted_payload[:attribute_model] || DEFAULT_ATTRIBUTE_MODEL
    validate_custom_attribute_limit(attribute_model)
  end
end
