class Api::V1::Accounts::PipelinesController < Api::V1::Accounts::BaseController
  include Api::V1::ResourceLimitsHelper

  require_permissions({
    index: 'pipelines.read',
    show: 'pipelines.read',
    create: 'pipelines.create',
    update: 'pipelines.update',
    destroy: 'pipelines.delete',
    archive: 'pipelines.update',
    set_as_default: 'pipelines.update',
    stats: 'pipelines.read',
    by_contact: 'pipelines.read',
    by_conversation: 'pipelines.read'
  })

  before_action :fetch_pipeline, only: [:show, :update, :destroy, :archive, :set_as_default]
  before_action :fetch_pipeline_for_stats, only: [:stats], if: -> { params[:id].present? }
  before_action :validate_pipeline_limit, only: [:create]
  before_action :fetch_contact_for_by_contact, only: [:by_contact]
  before_action :fetch_conversation_for_by_conversation, only: [:by_conversation]

  def index
    @pipelines = Pipeline.all
                        .accessible_by(Current.user)
                        .active
                        .includes(
                          pipeline_stages: [],
                          pipeline_items: [
                            :pipeline_stage,
                            conversation: [
                              :contact,
                              :assignee,
                              :inbox,
                            ]
                          ]
                        )
                        .order(:name)

    success_response(
      data: PipelineSerializer.serialize_collection(
        @pipelines,
        include_stages: true,
        include_items: true,
        include_tasks_info: true,
        include_services_info: true
      ),
      message: 'Pipelines retrieved successfully'
    )
  end

  def show
    success_response(
      data: PipelineSerializer.serialize(
        @pipeline,
        include_stages: true,
        include_items: true,
        include_tasks_info: true,
        include_services_info: true
      ),
      message: 'Pipeline retrieved successfully'
    )
  end

  def create
    # Check if user can create pipelines at the account level
    authorize Pipeline, :create?

    @pipeline = Pipeline.new(pipeline_params.merge(created_by: Current.user))

    ActiveRecord::Base.transaction do
      @pipeline.save!

      # Create custom stages if provided, otherwise create default stages
      if params[:stages].present?
        create_custom_stages(params[:stages])
      elsif params[:create_default_stages]
        create_default_stages
      end

      success_response(
        data: PipelineSerializer.serialize(@pipeline, include_stages: true),
        message: 'Pipeline created successfully',
        status: :created
      )
    end
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def update
    if @pipeline.update(pipeline_params)
      success_response(
        data: PipelineSerializer.serialize(@pipeline, include_stages: true),
        message: 'Pipeline updated successfully'
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @pipeline.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    if @pipeline.pipeline_items.exists?
      return error_response(
        ApiErrorCodes::CANNOT_DELETE_PIPELINE_WITH_CONVERSATIONS,
        'Cannot delete pipeline with active conversations',
        status: :unprocessable_entity
      )
    end

    @pipeline.destroy
    success_response(
      data: { id: @pipeline.id },
      message: 'Pipeline deleted successfully'
    )
  end

  def archive
    @pipeline.update!(is_active: false)
    success_response(
      data: PipelineSerializer.serialize(@pipeline),
      message: 'Pipeline archived successfully'
    )
  end

  def set_as_default
    @pipeline.update!(is_default: true)
    success_response(
      data: PipelineSerializer.serialize(@pipeline, include_stages: true),
      message: 'Pipeline marked as default successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to set pipeline as default',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def stats
    if params[:id].present?
      # Stats for a specific pipeline
      @stats = {
        total_items: @pipeline.item_count,
        stage_counts: @pipeline.stage_counts,
      }
    else
      # Stats for all pipelines
      pipelines = Pipeline.includes(:pipeline_items, :pipeline_stages)

      @stats = {
        total_pipelines: pipelines.count,
        active_pipelines: pipelines.where(is_active: true).count,
        inactive_pipelines: pipelines.where(is_active: false).count,
        total_items: pipelines.sum(&:item_count),
      }
    end

    success_response(
      data: @stats,
      message: 'Pipeline statistics retrieved successfully'
    )
  end

  def by_contact
    serialized_pipelines = fetch_pipelines_by_item_filter(
      filter_condition: { contact_id: @contact.id },
      item_filter: ->(item) { item.contact_id == @contact.id }
    )

    success_response(
      data: serialized_pipelines,
      message: 'Pipelines with contact items retrieved successfully'
    )
  rescue ActiveRecord::RecordNotFound => e
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      'Contact not found',
      details: e.message,
      status: :not_found
    )
  end

  def by_conversation
    serialized_pipelines = fetch_pipelines_by_item_filter(
      filter_condition: { conversation_id: @conversation.id },
      item_filter: ->(item) { item.conversation_id == @conversation.id }
    )

    success_response(
      data: serialized_pipelines,
      message: 'Pipelines with conversation items retrieved successfully'
    )
  rescue ActiveRecord::RecordNotFound => e
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      'Conversation not found',
      details: e.message,
      status: :not_found
    )
  end

  private

  def fetch_pipeline
    @pipeline = Pipeline.all
                          .includes(
                            :created_by,
                            pipeline_stages: [],
                            pipeline_items: [
                              :pipeline_stage,
                              :contact,
                              :tasks,
                              conversation: [
                                :contact,
                                :assignee,
                                :team,
                                :inbox,
                                messages: [:attachments, :sender]
                              ]
                            ]
                          )
                          .preload(
                            pipeline_items: {
                              conversation: :messages
                            }
                          )
                          .find(params[:id])
  end

  def fetch_pipeline_for_stats
    fetch_pipeline
  end

  def fetch_contact_for_by_contact
    @contact = Contact.find(params[:contact_id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::CONTACT_NOT_FOUND,
      "Contact with ID '#{params[:contact_id]}' not found",
      details: { contact_id: params[:contact_id] },
      status: :not_found
    )
  end

  def fetch_conversation_for_by_conversation
    conversation_id = params[:conversation_id]

    # Try to find by UUID first
    @conversation = Conversation.find_by(id: conversation_id)

    # If not found and it's a display_id (numeric), try finding by display_id
    if @conversation.nil? && conversation_id.to_s.match?(/\A\d+\z/)
      @conversation = Conversation.find_by(display_id: conversation_id)
    end

    unless @conversation
      error_response(
        ApiErrorCodes::RESOURCE_NOT_FOUND,
        "Conversation with ID '#{conversation_id}' not found",
        details: { conversation_id: conversation_id },
        status: :not_found
      )
    end
  end

  def pipeline_params
    permitted = params.require(:pipeline).permit(
      :name,
      :description,
      :pipeline_type,
      :visibility,
      custom_fields: {}
    )

    allowed_display_types = %w[text number currency percent link date list checkbox].freeze

    # Normalize custom_fields and keep only supported local attribute metadata
    if permitted[:custom_fields].present?
      attributes = permitted[:custom_fields]['attributes'] || []
      attributes = Array(attributes).map(&:to_s).reject(&:blank?)

      raw_definitions = permitted[:custom_fields]['attribute_definitions']
      attribute_definitions = if raw_definitions.is_a?(Hash)
                                raw_definitions.each_with_object({}) do |(key, value), acc|
                                  next if key.blank?
                                  next unless value.is_a?(Hash) || value.is_a?(ActionController::Parameters)

                                  definition = value.to_h.stringify_keys
                                  display_type = definition['attribute_display_type'].to_s
                                  next unless allowed_display_types.include?(display_type)

                                  normalized = {
                                    'attribute_display_name' => definition['attribute_display_name'].presence || key.to_s,
                                    'attribute_display_type' => display_type
                                  }

                                  if display_type == 'list'
                                    list_values = Array(definition['attribute_values']).map(&:to_s).reject(&:blank?)
                                    normalized['attribute_values'] = list_values if list_values.present?
                                  end

                                  acc[key.to_s] = normalized
                                end
                              else
                                {}
                              end

      attribute_definitions.slice!(*attributes)
      permitted[:custom_fields] = { 'attributes' => attributes }
      permitted[:custom_fields]['attribute_definitions'] = attribute_definitions if attribute_definitions.present?
    end

    permitted
  end

  def create_custom_stages(stages_data)
    stages_data.each_with_index do |stage_data, index|
      stage_attrs = {
        name: stage_data[:name] || stage_data['name'],
        color: stage_data[:color] || stage_data['color'] || '#60A5FA',
        position: stage_data[:position] || stage_data['position'] || (index + 1),
      }

      # Add description if provided
      if stage_data[:description].present? || stage_data['description'].present?
        stage_attrs[:automation_rules] = {
          description: stage_data[:description] || stage_data['description']
        }
      end

      @pipeline.pipeline_stages.create!(stage_attrs)
    end
  end

  def create_default_stages
    default_stages = case @pipeline.pipeline_type
                     when 'sales'
                       [
                         { name: 'Lead', color: '#60A5FA', position: 1 },
                         { name: 'Qualified', color: '#F59E0B', position: 2 },
                         { name: 'Proposal', color: '#10B981', position: 3 },
                         { name: 'Won', color: '#059669', position: 4},
                         { name: 'Lost', color: '#EF4444', position: 5}
                       ]
                     when 'support'
                       [
                         { name: 'New', color: '#60A5FA', position: 1 },
                         { name: 'In Progress', color: '#F59E0B', position: 2 },
                         { name: 'Waiting', color: '#8B5CF6', position: 3 },
                         { name: 'Resolved', color: '#059669', position: 4},
                         { name: 'Closed', color: '#6B7280', position: 5}
                       ]
                     else
                       [
                         { name: 'To Do', color: '#60A5FA', position: 1 },
                         { name: 'In Progress', color: '#F59E0B', position: 2 },
                         { name: 'Done', color: '#059669', position: 3}
                       ]
                     end

    default_stages.each do |stage_attrs|
      @pipeline.pipeline_stages.create!(stage_attrs)
    end
  end

  def fetch_pipelines_by_item_filter(filter_condition:, item_filter:)
    # Buscar todos os pipelines que têm items que correspondem ao filtro
    pipeline_ids_with_items = PipelineItem
                                .where(filter_condition)
                                .distinct
                                .pluck(:pipeline_id)

    # Carregar pipelines com eager loading otimizado incluindo stages e items
    pipelines = Pipeline.all
                         .where(id: pipeline_ids_with_items)
                         .includes(
                           pipeline_stages: [],
                           pipeline_items: [
                             :pipeline_stage,
                             conversation: [
                               :contact,
                               :assignee,
                               :inbox,
                             ]
                           ]
                         )
                         .order(:name)

    # Filtrar items de cada pipeline e preparar para serialização
    pipelines.each do |pipeline|
      # Filtrar items que correspondem ao filtro para este pipeline
      filtered_items = pipeline.pipeline_items.select(&item_filter)

      # Substituir temporariamente os items filtrados
      pipeline.association(:pipeline_items).target = filtered_items
    end

    # Serializar collection com stages e items incluídos
    PipelineSerializer.serialize_collection(
      pipelines,
      include_stages: true,
      include_items: true,
      include_tasks_info: true,
      include_services_info: true
    )
  end
end
