# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength
class Api::V1::PipelineItemsController < Api::V1::BaseController
  include Events::Types

  before_action :set_pipeline
  before_action :set_pipeline_item, only: [:update, :destroy, :move_to_stage, :update_conversation, :update_custom_fields]
  before_action :ensure_authorized_user

  def index
    @pipeline_items = @pipeline.pipeline_items.includes(
      :conversation,
      :pipeline_stage,
      conversation: [
        :contact,
        :assignee,
        :team,
        messages: [:attachments, :sender]
      ]
    )

    apply_filters
    apply_sorting
    
    success_response(
      data: PipelineItemSerializer.serialize_collection(@pipeline_items, include_entity: true),
      message: 'Pipeline items retrieved successfully'
    )
  end

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def create
    conversation = nil
    contact = nil

    if params[:type] == 'conversation'
      # Try to find by id (UUID) first, then by display_id (integer)
      # This ensures we match UUIDs correctly
      conversation = Conversation.find_by(id: params[:item_id]) ||
                    Conversation.find_by(display_id: params[:item_id])

      if conversation.nil?
        error_response(
          ApiErrorCodes::CONVERSATION_NOT_FOUND,
          'Conversation not found'
        )
        return
      end

      # Check if conversation is already in THIS specific pipeline
      if @pipeline.pipeline_items.exists?(conversation: conversation)
        error_response(
          ApiErrorCodes::BUSINESS_RULE_VIOLATION,
          'Item is already in this pipeline'
        )
        return
      end
    end

    if params[:type] == 'contact'
      contact = Contact.find_by(id: params[:item_id])

      if contact.nil?
        error_response(
          ApiErrorCodes::CONTACT_NOT_FOUND,
          'Contact not found'
        )
        return
      end

      # Check if contact is already in THIS specific pipeline
      if @pipeline.pipeline_items.exists?(contact: contact)
        error_response(
          ApiErrorCodes::BUSINESS_RULE_VIOLATION,
          'Contact is already in this pipeline'
        )
        return
      end
    end

    # If no stage_id provided, use the first stage of the pipeline
    stage_id = params[:pipeline_stage_id] || @pipeline.pipeline_stages.order(:position, :id).first&.id

    if stage_id.nil?
      error_response(
        ApiErrorCodes::BUSINESS_RULE_VIOLATION,
        'Pipeline has no stages available'
      )
      return
    end

    pipeline_stage = @pipeline.pipeline_stages.find(stage_id)

    if conversation.present?
      # Check if conversation already exists in this pipeline
      existing_pc = @pipeline.pipeline_items.find_by(conversation: conversation)

      if existing_pc
        error_response(
          ApiErrorCodes::BUSINESS_RULE_VIOLATION,
          "Item already exists in this pipeline in stage '#{existing_pc.pipeline_stage.name}'",
          details: {
            existing_stage: existing_pc.pipeline_stage.name,
            existing_stage_id: existing_pc.pipeline_stage_id
          }
        )
        return
      end
    end

    @pipeline_item = @pipeline.pipeline_items.new(
      conversation: conversation,
      contact: contact,
      pipeline_stage: pipeline_stage,
      assigned_by: Current.user,
      custom_fields: params[:custom_fields] || {}
    )

    if @pipeline_item.save
      # Reload to ensure all associations are loaded
      @pipeline_item.reload

      # Include necessary associations for the view
      @pipeline_item = @pipeline.pipeline_items.includes(
        :conversation,
        :pipeline_stage,
        conversation: [
          :contact,
          :assignee,
          :team,
          messages: [:attachments, :sender]
        ]
      ).find(@pipeline_item.id)

      dispatch_conversation_updated_event(@pipeline_item.conversation) if @pipeline_item.conversation

      success_response(
        data: PipelineItemSerializer.serialize(@pipeline_item, include_entity: true),
        message: 'Pipeline item created successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        @pipeline_item.errors.full_messages.join(', '),
        details: @pipeline_item.errors.as_json
      )
    end
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message
    )
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      'Stage not found in this pipeline'
    )
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def update
    new_stage_id = params[:pipeline_stage_id]
    stage_changed = false

    if new_stage_id.present? && new_stage_id.to_s != @pipeline_item.pipeline_stage_id.to_s
      new_stage = @pipeline.pipeline_stages.find(new_stage_id)

      unless @pipeline_item.move_to_stage(new_stage, Current.user)
        return error_response(
          ApiErrorCodes::OPERATION_FAILED,
          'Failed to move item to new stage',
          status: :unprocessable_entity
        )
      end

      stage_changed = true
    end

    @pipeline_item.update!(custom_fields: params[:custom_fields]) if params[:custom_fields].present?

    if params[:notes].present? && stage_changed
      latest_movement = @pipeline_item.stage_movements.order(:created_at).last
      latest_movement&.update!(notes: params[:notes])
    end

    dispatch_conversation_updated_event(@pipeline_item.conversation) if stage_changed

    success_response(
      data: PipelineItemSerializer.serialize(@pipeline_item.reload, include_entity: true),
      message: 'Pipeline item updated successfully'
    )
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      'Stage not found in this pipeline',
      status: :not_found
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message,
      details: format_validation_errors(e.record.errors),
      status: :unprocessable_entity
    )
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def update_notesconversation
    # Handle stage change
    if params[:stage_id].present?
      new_stage = @pipeline.pipeline_stages.find(params[:stage_id])

      # Move to new stage if different
      if @pipeline_item.pipeline_stage_id != new_stage.id && !@pipeline_item.move_to_stage(new_stage, Current.user)
        return error_response(
          ApiErrorCodes::OPERATION_FAILED,
          'Failed to move conversation to new stage',
          status: :unprocessable_entity
        )
      end
    end

    # Update custom fields and notes
    update_params = {}
    update_params[:custom_fields] = params[:custom_fields] if params[:custom_fields].present?

    @pipeline_item.update!(update_params) if update_params.any?

    # Add notes to the latest movement if provided
    if params[:notes].present?
      latest_movement = @pipeline_item.stage_movements.last
      if latest_movement
        latest_movement.update!(notes: params[:notes])
      else
        # Create a movement if none exists (shouldn't happen normally)
        @pipeline_item.stage_movements.create!(
          to_stage: @pipeline_item.pipeline_stage,
          moved_by: Current.user,
          movement_type: :manual,
          notes: params[:notes]
        )
      end
    end

    dispatch_conversation_updated_event(@pipeline_item.conversation)

    success_response(
      data: { pipeline_item: @pipeline_item.push_event_data },
      message: 'Item updated successfully'
    )
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      'Stage not found in this pipeline',
      status: :not_found
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message,
      details: format_validation_errors(e.record.errors),
      status: :unprocessable_entity
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      'Error updating conversation',
      details: e.message,
      status: :unprocessable_entity
    )
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def destroy
    conversation = @pipeline_item.conversation
    @pipeline_item.destroy!

    # Only update conversation if it exists (pipeline items can be contacts without conversations)
    if conversation.present?
      # Reload conversation to clear cached associations
      conversation.reload

      # Update conversation timestamp to ensure frontend gets the update
      # Using touch to update timestamps for frontend reactivity
      conversation.touch # rubocop:disable Rails/SkipsModelValidations

      # Debug log
      Rails.logger.info "Pipeline conversation removed. Item #{conversation.id} has " \
                        "#{conversation.pipeline_items.count} pipeline conversations"

      dispatch_conversation_updated_event(conversation)
    end

    success_response(
      data: { id: @pipeline_item.id },
      message: 'Item removed from pipeline successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      'Error removing item from pipeline',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  # rubocop:disable Metrics/MethodLength
  def move_to_stage
    begin
      new_stage = @pipeline.pipeline_stages.find(params[:new_stage_id])
    rescue ActiveRecord::RecordNotFound
      return error_response(
        ApiErrorCodes::RESOURCE_NOT_FOUND,
        'Stage not found in this pipeline',
        status: :not_found
      )
    end

    notes = params[:notes]

    if @pipeline_item.move_to_stage(new_stage, Current.user)
      # Add notes to the latest movement if provided
      if notes.present?
        latest_movement = @pipeline_item.stage_movements.last
        latest_movement.update!(notes: notes)
      end

      dispatch_conversation_updated_event(@pipeline_item.conversation)

      success_response(
        data: { pipeline_item: @pipeline_item.push_event_data },
        message: 'Item moved successfully'
      )
    else
      error_response(
        ApiErrorCodes::OPERATION_FAILED,
        'Failed to move conversation',
        status: :unprocessable_entity
      )
    end
  end
  # rubocop:enable Metrics/MethodLength

  def update_custom_fields
    @pipeline_item.update!(custom_fields: params[:custom_fields])
    success_response(
      data: { custom_fields: @pipeline_item.custom_fields },
      message: 'Custom fields updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message,
      details: format_validation_errors(e.record.errors),
      status: :unprocessable_entity
    )
  end

  # rubocop:disable Metrics/MethodLength
  def bulk_move
    conversation_ids = params[:conversation_ids] || []
    new_stage = @pipeline.pipeline_stages.find(params[:new_stage_id])
    notes = params[:notes]

    moved_count = 0

    ActiveRecord::Base.transaction do
      conversation_ids.each do |conversation_id|
        pipeline_item = @pipeline.pipeline_items.find(conversation_id)
        next unless pipeline_item.move_to_stage(new_stage, Current.user)

        if notes.present?
          latest_movement = pipeline_item.stage_movements.last
          latest_movement.update!(notes: notes)
        end
        moved_count += 1
      end
    end

    success_response(
      data: { moved_count: moved_count },
      message: "#{moved_count} conversations moved successfully"
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      'Failed to move conversations',
      details: e.message,
      status: :unprocessable_entity
    )
  end
  # rubocop:enable Metrics/MethodLength

  def stats
    @stats = {
      total_conversations: @pipeline_items.count,
      conversations_with_services: @pipeline_items.where("custom_fields ? 'services'").count,
      total_services_value: calculate_total_services_value,
      currency_breakdown: calculate_currency_breakdown,
      average_services_per_conversation: calculate_average_services_per_conversation
    }
    success_response(
      data: @stats,
      message: 'Pipeline statistics retrieved successfully'
    )
  end

  def available_conversations
    # Get conversation IDs that are already in THIS specific pipeline
    conversation_ids_in_pipeline = @pipeline.pipeline_items
                                             .where.not(conversation_id: nil)
                                             .pluck(:conversation_id)

    current_conversations = Conversation.all
                      .joins(:contact, :inbox)
                      .where.not(conversations: { id: conversation_ids_in_pipeline })
                      .where.not(status: 'resolved')
                      .includes(:contact, :inbox, :assignee, :team)
                      .order(last_activity_at: :desc)
                      .limit(50)

    # Apply search filter if provided
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      current_conversations = current_conversations.where(
        'conversations.id::text ILIKE ? OR conversations.display_id::text ILIKE ? OR ' \
        'contacts.name ILIKE ? OR contacts.email ILIKE ? OR contacts.phone_number ILIKE ?',
        search_term, search_term, search_term, search_term, search_term
      )
    end

    success_response(
      data: ConversationSerializer.serialize_collection(current_conversations, include_messages: false),
      message: 'Available conversations retrieved successfully'
    )
  end

  def available_contacts
    # Get contacts that are NOT already in THIS specific pipeline
    contacts_in_current_pipeline = @pipeline.pipeline_items.where.not(contact_id: nil).select(:contact_id)

    current_contacts = Contact.all
                       .where.not(contacts: { id: contacts_in_current_pipeline })
                       .order(name: :desc)
                       .limit(50)

    # Apply search filter if provided
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      current_contacts = current_contacts.where(
        'contacts.id::text ILIKE ? OR contacts.name ILIKE ? OR ' \
        'contacts.email ILIKE ? OR contacts.phone_number ILIKE ?',
        search_term, search_term, search_term, search_term
      )
    end

    Rails.logger.info "Current contacts: #{current_contacts.inspect}"

    success_response(
      data: ContactSerializer.serialize_collection(current_contacts),
      message: 'Available contacts retrieved successfully'
    )
  end

  private

  def dispatch_conversation_updated_event(conversation)
    # Update conversation timestamp to ensure frontend gets the update (only for deals, not leads)
      # Using touch to sync conversation timestamps with frontend
      if conversation.present?
        conversation.touch # rubocop:disable Rails/SkipsModelValidations
        # Dispatch events to update frontend
        Rails.application.config.dispatcher.dispatch(CONVERSATION_UPDATED, Time.zone.now, conversation: conversation)
      end
  end

  def set_pipeline
    @pipeline = Pipeline.find(params[:pipeline_id])
    authorize @pipeline, :view? unless service_authenticated?
  end

  # rubocop:disable Metrics/AbcSize
  def set_pipeline_item
    # For destroy and move_to_stage actions, try to find by conversation_id first, then by pipeline_item id
    if %w[destroy move_to_stage update_conversation].include?(action_name)
      # First try to find by conversation display_id
      conversation = Conversation.find_by(display_id: params[:id])
      @pipeline_item = @pipeline.pipeline_items.find_by(conversation: conversation) if conversation

      # If not found, try by conversation id (UUID)
      if @pipeline_item.nil?
        conversation = Conversation.find_by(id: params[:id])
        @pipeline_item = @pipeline.pipeline_items.find_by(conversation: conversation) if conversation
      end

      # If still not found, try by pipeline_item id as final fallback
      @pipeline_item = @pipeline.pipeline_items.find_by(id: params[:id]) if @pipeline_item.nil?

      if @pipeline_item.nil?
        error_response(
          ApiErrorCodes::RESOURCE_NOT_FOUND,
          "Pipeline conversation #{params[:id]} not found in pipeline #{@pipeline.name}",
          status: :not_found
        )
        return
      end
    else
      # For other actions (update), find by pipeline_item id only
      @pipeline_item = @pipeline.pipeline_items.find_by(id: params[:id])

      if @pipeline_item.nil?
        error_response(
          ApiErrorCodes::RESOURCE_NOT_FOUND,
          "Pipeline conversation #{params[:id]} not found in pipeline #{@pipeline.name}",
          status: :not_found
        )
        return
      end
    end
  end
  # rubocop:enable Metrics/AbcSize

  def pipeline_item_params
    params.require(:pipeline_item).permit(custom_fields: {})
  end

  def calculate_total_services_value
    @pipeline_items.sum(&:services_total_value)
  end

  def calculate_currency_breakdown
    breakdown = {}
    @pipeline_items.each do |pc|
      next unless pc.custom_fields&.dig('services')&.any?

      currency = pc.custom_fields['currency'] || 'BRL'
      breakdown[currency] ||= { count: 0, total_value: 0 }
      breakdown[currency][:count] += 1
      breakdown[currency][:total_value] += pc.services_total_value
    end
    breakdown
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def calculate_average_services_per_conversation
    conversations_with_services = @pipeline_items.select { |pc| pc.custom_fields&.dig('services')&.any? }
    return 0 if conversations_with_services.empty?

    total_services = conversations_with_services.sum do |pc|
      pc.custom_fields['services']&.length || 0
    end

    (total_services.to_f / conversations_with_services.length).round(2)
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def filter_by_stage
    @pipeline_items.where(pipeline_stage_id: params[:stage_id])
  end

  def search_conversations
    search_term = "%#{params[:search]}%"
    @pipeline_items.joins(conversation: :contact)
                           .where(
                             'contacts.name ILIKE ? OR contacts.email ILIKE ? OR conversations.id::text ILIKE ?',
                             search_term, search_term, search_term
                           )
  end

  def stage_statistics
    @pipeline.pipeline_stages.map do |stage|
      {
        stage_id: stage.id,
        stage_name: stage.name,
        item_count: stage.pipeline_items.count,
        color: stage.color
      }
    end
  end

  def recent_movements_data
    StageMovement.for_pipeline(@pipeline)
                 .includes(:pipeline_item, :from_stage, :to_stage, :moved_by)
                 .recent
                 .limit(10)
                 .map(&:push_event_data)
  end

  def apply_filters
    @pipeline_items = filter_by_stage if params[:stage_id].present?
    @pipeline_items = search_conversations if params[:search].present?
  end

  def apply_sorting
    sort_by = params[:sort_by] || 'created_at'
    sort_order = params[:sort_order] || 'desc'

    @pipeline_items = case sort_by
                      when 'created_at'
                        @pipeline_items.order(created_at: sort_order)
                      when 'updated_at'
                        @pipeline_items.order(updated_at: sort_order)
                      when 'stage_name'
                        @pipeline_items.joins(:pipeline_stage).order("pipeline_stages.name #{sort_order}")
                      when 'contact_name'
                        @pipeline_items.joins(conversation: :contact).order("contacts.name #{sort_order}")
                      else
                        @pipeline_items.order(created_at: :desc)
                      end
  end

  def ensure_authorized_user
    return if service_authenticated?

    authorize @pipeline, :view?
  end
end
# rubocop:enable Metrics/ClassLength
