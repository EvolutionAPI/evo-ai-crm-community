class Api::V1::PipelinesController < Api::V1::BaseController
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
    by_conversation: 'pipelines.read',
    dependents: 'pipelines.update'
  })

  before_action :fetch_pipeline, only: [:show, :update, :destroy, :archive, :set_as_default]
  before_action :fetch_pipeline_lean, only: [:dependents]
  before_action :reject_update_without_permitted_attributes, only: [:update]
  before_action :fetch_pipeline_for_stats, only: [:stats], if: -> { params[:id].present? }
  before_action :validate_pipeline_limit, only: [:create]
  before_action :fetch_contact_for_by_contact, only: [:by_contact]
  before_action :fetch_conversation_for_by_conversation, only: [:by_conversation]

  def index
    # The pipelines list screen renders only pipeline-level cards (name, item_count,
    # stage count, type) — it never reads stages[].items. So we serialize stages
    # without their items here and skip the heavy contact/conversation/message
    # preload entirely. The full board (stages + items + conversations) is served
    # by #show via GET /pipelines/:id when the user opens a pipeline.
    # include_services_info: o card de cada funil na LISTA mostra o "Valor Total" (soma dos
    # serviços dos itens) — antes vinha vazio porque o index não pedia esse cálculo. Pré-carrega
    # pipeline_items pra a soma de services_total_value não disparar N+1.
    # Inactive pipelines are hidden by default because every picker in the app (dashboard,
    # kanban, automations, agents) lists pipelines through this endpoint. The pipelines
    # management screen opts in so a deactivated pipeline stays visible and can be reactivated.
    @pipelines = policy_scope(Pipeline)
                        .includes(:pipeline_teams, pipeline_stages: [], pipeline_items: [])
                        .order(:name)
    @pipelines = @pipelines.active unless include_inactive?

    success_response(
      data: PipelineSerializer.serialize_collection(
        @pipelines,
        include_stages: true,
        include_items: false,
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
        include_services_info: true,
        include_labels: true
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
    # EVO-2205: only ACTIVE items block deletion. This used to reject on ANY
    # pipeline_item while reporting it as "active conversations" — two lies at once,
    # since an item can also be a contact-only lead. The error CODE keeps its legacy
    # name because it is a published contract the frontend already maps; the rule it
    # stands for is the guard below.
    #
    # Two things this guard depends on, both unbuilt (see EVO-2205 for the decision):
    #   1. Nothing ever sets `pipeline_item.completed_at` — no endpoint, no service,
    #      never in this repo's history. So `.active` is a no-op in practice today and
    #      "a pipeline whose items are all completed" is an unreachable state.
    #   2. When completing an item does become possible, decide what delete means for
    #      completed ones BEFORE shipping it: `Pipeline has_many :pipeline_items,
    #      dependent: :destroy` hard-deletes them here, along with their stage_movements
    #      history, tasks and products, with no confirmation.
    if @pipeline.pipeline_items.active.exists?
      return error_response(
        ApiErrorCodes::CANNOT_DELETE_PIPELINE_WITH_CONVERSATIONS,
        'Cannot delete pipeline with active items',
        status: :unprocessable_entity
      )
    end

    @pipeline.destroy
    success_response(
      data: { id: @pipeline.id },
      message: 'Pipeline deleted successfully'
    )
  end

  # What would keep running against this pipeline after it is archived. Answers the
  # confirmation dialog, so archiving stops being a blind action. Only capture forms are
  # covered today — automations and journeys are separate cards (EVO-2199), so the
  # payload names what it inspected instead of implying the list is exhaustive.
  def dependents
    scope = forms_targeting_pipeline

    success_response(
      data: {
        inspected: ['crm_forms'],
        count: scope.count,
        published_count: scope.where(published: true).count,
        names_redacted: !may_read_forms?,
        crm_forms: may_read_forms? ? serialize_dependent_forms(scope.limit(DEPENDENTS_LIMIT)) : []
      },
      message: 'Pipeline dependents retrieved successfully'
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
      # Stats for a specific pipeline. Inclui VALORES (não só contagem): total do funil +
      # valor por etapa, do mesmo jeito que a UI mostra. Sem isto, relatórios financeiros
      # (inclusive do assistente) concluíam "não há valores" apesar dos deals terem serviços.
      @stats = {
        total_items: @pipeline.item_count,
        stage_counts: @pipeline.stage_counts,
        total_value: @pipeline.total_value,
        stage_values: @pipeline.stage_values,
        currency: 'BRL',
      }
    else
      # Stats for all pipelines
      pipelines = Pipeline.includes(:pipeline_items, :pipeline_stages)

      @stats = {
        total_pipelines: pipelines.count,
        active_pipelines: pipelines.where(is_active: true).count,
        inactive_pipelines: pipelines.where(is_active: false).count,
        total_items: pipelines.sum(&:item_count),
        total_value: pipelines.sum(&:total_value),
        currency: 'BRL',
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
                            :pipeline_teams,
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

  # dependents only needs the pipeline row to key the crm_forms lookup, so it skips the
  # heavy item/conversation/message eager-load that fetch_pipeline does for show-style
  # actions — loading that whole graph to answer a confirmation dialog is wasted work.
  def fetch_pipeline_lean
    @pipeline = Pipeline.find(params[:id])
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

  # A payload whose keys are all unpermitted reduces to {} and would answer 200,
  # reporting success for an update that never happened.
  def reject_update_without_permitted_attributes
    return if pipeline_params.present?

    error_response(
      ApiErrorCodes::INVALID_PARAMETER,
      'No updatable attributes were provided',
      status: :unprocessable_entity
    )
  end

  DEPENDENTS_LIMIT = 50

  # A form reaches a pipeline through its default destination OR through a routing rule
  # that overrides it (CrmForm#resolve_destination). Matching only the default would let
  # the dialog report "nothing depends on this" while rule-routed leads keep arriving.
  def forms_targeting_pipeline
    CrmForm.where(default_pipeline_id: @pipeline.id)
           .or(CrmForm.where('routing_rules @> ?', [{ pipeline_id: @pipeline.id }].to_json))
           .order(:name)
  end

  def serialize_dependent_forms(forms)
    forms.map do |form|
      {
        id: form.id,
        name: form.name,
        title: form.title,
        published: form.published,
        via: form.default_pipeline_id == @pipeline.id ? 'default' : 'routing_rule'
      }
    end
  end

  # Form names belong to the crm_forms resource. Someone allowed to archive a pipeline is
  # not automatically allowed to enumerate forms, so the counts are shared and the names
  # are withheld when the caller lacks that grant.
  def may_read_forms?
    return @may_read_forms if defined?(@may_read_forms)

    @may_read_forms = Current.service_authenticated == true ||
                      has_user_permission?(Current.user&.id, 'crm_forms.read')
  end

  def include_inactive?
    ActiveModel::Type::Boolean.new.cast(params[:include_inactive])
  end

  def pipeline_params
    return @pipeline_params if defined?(@pipeline_params)

    attributes = [:name, :description, :pipeline_type, :visibility]
    # Activation is toggled through update only; a pipeline is always born active.
    attributes << :is_active if action_name == 'update'

    permitted = params.require(:pipeline).permit(*attributes, custom_fields: {}, team_ids: [])

    # EVO-2222: `team_ids` carries the team picker's selection for a `team`-visible
    # pipeline; the has_many :through persists it. It is NOT a Pipeline column, so
    # ActionController::ParamsWrapper never copies it into params[:pipeline] — and the
    # client posts the attributes bare (pipelinesService.createPipeline/updatePipeline),
    # exactly like `stages`. Reading only the envelope is how it got dropped in the
    # first place, so both shapes are accepted here.
    permitted[:team_ids] = submitted_team_ids if team_ids_submitted?

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

    @pipeline_params = permitted
  end

  # Whichever of the two shapes carried `team_ids`, or nil when the client did not send
  # it at all. An explicit `[]` means "clear the teams", so this asks about the KEY.
  def team_ids_source
    return @team_ids_source if defined?(@team_ids_source)

    envelope = params[:pipeline]

    @team_ids_source = if envelope.is_a?(ActionController::Parameters) && envelope.key?(:team_ids)
                         envelope
                       elsif params.key?(:team_ids)
                         params
                       end
  end

  def team_ids_submitted?
    !team_ids_source.nil?
  end

  # slice first: the top-level source carries every other request param, and permitting
  # over it would report them all as unpermitted.
  def submitted_team_ids
    Array(team_ids_source.slice(:team_ids).permit(team_ids: [])[:team_ids])
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

    # Carregar pipelines com eager loading otimizado incluindo stages e items.
    # EVO-2222: escopar por visibilidade — o menu de pipelines na conversa/contato só
    # mostra pipelines que o usuário pode ver (público/próprio/default/time). Antes
    # retornava todos, independente da visibilidade. Efeito colateral esperado: um item
    # que um colega criou dentro de um pipeline privado dele some deste menu.
    pipelines = policy_scope(Pipeline)
                         .where(id: pipeline_ids_with_items)
                         .includes(
                           :pipeline_teams,
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
