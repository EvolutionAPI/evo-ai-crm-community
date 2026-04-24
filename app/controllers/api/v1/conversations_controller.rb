class Api::V1::ConversationsController < Api::V1::BaseController
  include Events::Types
  include DateRangeHelper
  include HmacConcern
  include ConversationResolver

  # Configuração de permissões - Define exatamente quais actions precisam de verificação
  require_permissions({
    index: 'conversations.read',
    show: 'conversations.read',
    create: 'conversations.create',
    update: 'conversations.update',
    destroy: 'conversations.delete',
    toggle_status: 'conversations.toggle_status',
    toggle_priority: 'conversations.toggle_priority',
    custom_attributes: 'conversations.custom_attributes',
    pin: 'conversations.update',
    unpin: 'conversations.update',
    archive: 'conversations.update',
    unarchive: 'conversations.update',
    transcript: 'conversations.export',
    available_for_pipeline: 'conversations.read'
  })
  
  before_action :conversation, except: [:index, :meta, :search, :create, :filter]
  before_action :inbox, :contact, :contact_inbox, only: [:create]

  ATTACHMENT_RESULTS_PER_PAGE = 100

  def index
    result = conversation_finder.perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
    conversation_ids = @conversations.map(&:id)

    success_response(
      data: ConversationSerializer.serialize_collection(
        @conversations,
        include_messages: false,
        include_labels: true,
        unread_counts: unread_counts_map(conversation_ids),
        last_non_activity_messages: last_non_activity_messages_map(conversation_ids),
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      ),
      meta: conversations_pagination_meta,
      message: 'Conversations retrieved successfully'
    )
  end

  def meta
    result = conversation_finder.perform
    @conversations_count = result[:count]
    
    success_response(
      data: { count: @conversations_count },
      message: 'Conversation metadata retrieved successfully'
    )
  end

  def search
    result = conversation_finder.perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
    conversation_ids = @conversations.map(&:id)
    
    success_response(
      data: ConversationSerializer.serialize_collection(
        @conversations,
        include_messages: false,
        include_labels: true,
        unread_counts: unread_counts_map(conversation_ids),
        last_non_activity_messages: last_non_activity_messages_map(conversation_ids),
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      ),
      meta: conversations_pagination_meta,
      message: 'Conversations search completed successfully'
    )
  end

  def attachments
    @attachments_count = @conversation.attachments.count
    @attachments = @conversation.attachments
                                .includes(:message)
                                .order(created_at: :desc)
                                .page(attachment_params[:page])
                                .per(ATTACHMENT_RESULTS_PER_PAGE)
    
    paginated_response(
      data: @attachments.map do |attachment|
        {
          id: attachment.id.to_s,
          message_id: attachment.message_id&.to_s || attachment.attachable_id&.to_s,
          file_type: attachment.file_type,
          extension: attachment.extension,
          data_url: attachment.file_url || '',
          thumb_url: attachment.thumb_url,
          file_size: attachment.file&.attached? ? attachment.file.blob.byte_size : 0,
          fallback_title: attachment.fallback_title,
          coordinates_lat: attachment.coordinates_lat || 0,
          coordinates_long: attachment.coordinates_long || 0,
          external_url: attachment.external_url,
          meta: attachment.meta || {},
          created_at: attachment.created_at.to_i
        }
      end,
      collection: @attachments,
      message: 'Conversation attachments retrieved successfully'
    )
  end

  def show
    success_response(
      data: ConversationSerializer.serialize(
        @conversation,
        include_messages: true,
        include_labels: true,
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      ),
      message: 'Conversation retrieved successfully'
    )
  end

  def create
    ActiveRecord::Base.transaction do
      @conversation = ConversationBuilder.new(params: params, contact_inbox: @contact_inbox).perform
      Messages::MessageBuilder.new(Current.user, @conversation, params[:message]).perform if params[:message].present?
      
      success_response(
        data: ConversationSerializer.serialize(
          @conversation,
          include_messages: true,
          include_labels: true,
          labels_by_title: labels_by_title,
          labels_by_id: labels_by_id
        ),
        message: 'Conversation created successfully',
        status: :created
      )
    end
  rescue StandardError => e
    Rails.logger.error "Conversation creation failed: #{e.message}"
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: 'Conversation creation failed',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def update
    if @conversation.update(permitted_update_params)
      success_response(
        data: ConversationSerializer.serialize(
          @conversation,
          include_messages: false,
          include_labels: true,
          labels_by_title: labels_by_title,
          labels_by_id: labels_by_id
        ),
        message: 'Conversation updated successfully'
      )
    else
      error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Validation failed',
        details: @conversation.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def filter
    result = ::Conversations::FilterService.new(params.permit!, current_user, nil).perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
    conversation_ids = @conversations.map(&:id)

    success_response(
      data: ConversationSerializer.serialize_collection(
        @conversations,
        include_messages: false,
        include_labels: true,
        unread_counts: unread_counts_map(conversation_ids),
        last_non_activity_messages: last_non_activity_messages_map(conversation_ids),
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      ),
      meta: conversations_pagination_meta,
      message: 'Conversations filtered successfully'
    )
  rescue CustomExceptions::CustomFilter::InvalidAttribute,
         CustomExceptions::CustomFilter::InvalidOperator,
         CustomExceptions::CustomFilter::InvalidQueryOperator,
         CustomExceptions::CustomFilter::InvalidValue => e
    error_response(
      code: ApiErrorCodes::INVALID_PARAMETER,
      message: 'Invalid filter parameters',
      details: e.message,
      status: :bad_request
    )
  end

  def available_for_pipeline
    # Get all conversations that are open or pending and NOT already in any pipeline
    @available_conversations = Conversation.joins(:contact, :inbox)
                                      .where.missing(:pipeline_items)
                                      .where(status: %w[open pending])
                                      .includes(:contact, :inbox, :assignee, :team)
                                      .order(last_activity_at: :desc)
                                      .limit(50)

    # Apply search filter if provided
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      @available_conversations = @available_conversations.where(
        'conversations.id::text ILIKE ? OR contacts.name ILIKE ? OR contacts.email ILIKE ? OR contacts.phone_number ILIKE ?',
        search_term, search_term, search_term, search_term
      )
    end

    success_response(
      data: ConversationSerializer.serialize_collection(@available_conversations, include_messages: false),
      message: 'Available conversations for pipeline retrieved successfully'
    )
  end

  def mute
    @conversation.mute!
    success_response(
      data: { id: @conversation.id, muted: true },
      message: 'Conversation muted successfully'
    )
  end

  def unmute
    @conversation.unmute!
    success_response(
      data: { id: @conversation.id, muted: false },
      message: 'Conversation unmuted successfully'
    )
  end

  def transcript
    if params[:email].blank?
      return error_response(
        code: ApiErrorCodes::MISSING_REQUIRED_FIELD,
        message: 'Email parameter is required',
        status: :bad_request
      )
    end

    ConversationReplyMailer.with(account: nil).conversation_transcript(@conversation, params[:email])&.deliver_later
    success_response(
      data: { email: params[:email] },
      message: 'Transcript email scheduled for delivery'
    )
  end

  def toggle_status
    # FIXME: move this logic into a service object
    if pending_to_open_by_bot?
      @conversation.bot_handoff!
    elsif params[:status].present?
      set_conversation_status
      @status = @conversation.save!
    else
      @status = @conversation.toggle_status
    end
    assign_conversation if should_assign_conversation?
    
    success_response(
      data: ConversationSerializer.serialize(@conversation, include_messages: false),
      message: 'Conversation status toggled successfully'
    )
  end

  def pending_to_open_by_bot?
    return false unless Current.user.is_a?(AgentBot)

    @conversation.status == 'pending' && params[:status] == 'open'
  end

  def should_assign_conversation?
    @conversation.status == 'open' && Current.user.is_a?(User) && Current.user&.agent?
  end

  def toggle_priority
    @conversation.toggle_priority(params[:priority])
    success_response(
      data: { id: @conversation.id, priority: @conversation.priority },
      message: 'Conversation priority toggled successfully'
    )
  end

  def toggle_typing_status
    typing_status_manager = ::Conversations::TypingStatusManager.new(@conversation, current_user, params)
    typing_status_manager.toggle_typing_status
    success_response(
      data: {},
      message: 'Typing status updated successfully'
    )
  end

  def update_last_seen
    dispatch_messages_read_event if assignee?

    update_last_seen_on_conversation(DateTime.now.utc, assignee?)
    
    success_response(
      data: {},
      message: 'Last seen updated successfully'
    )
  end

  def unread
    Rails.configuration.dispatcher.dispatch(Events::Types::CONVERSATION_UNREAD, Time.zone.now, conversation: @conversation)

    last_incoming_message = @conversation.messages.incoming.last
    last_seen_at = last_incoming_message.created_at - 1.second if last_incoming_message.present?
    update_last_seen_on_conversation(last_seen_at, true)

    success_response(
      data: {},
      message: 'Unread updated successfully'
    )
  end

  def pin
    update_custom_attribute('pinned', true, 'Conversation pinned successfully')
  end

  def unpin
    update_custom_attribute('pinned', false, 'Conversation unpinned successfully')
  end

  def archive
    update_custom_attribute('archived', true, 'Conversation archived successfully')
  end

  def unarchive
    update_custom_attribute('archived', false, 'Conversation unarchived successfully')
  end

  private

  def update_custom_attribute(attribute_key, value, success_message)
    custom_attributes = (@conversation.custom_attributes || {}).merge(attribute_key => value)

    if @conversation.update(custom_attributes: custom_attributes)
      success_response(
        data: ConversationSerializer.serialize(
          @conversation,
          include_messages: false,
          include_labels: true,
          labels_by_title: labels_by_title,
          labels_by_id: labels_by_id
        ),
        message: success_message
      )
    else
      error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Validation failed',
        details: @conversation.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def unread_counts_map(conversation_ids)
    return {} if conversation_ids.blank?

    connection = ActiveRecord::Base.connection
    quoted_ids = quoted_uuid_list(conversation_ids, connection)
    incoming_type = Message.message_types[:incoming]

    # Count at most 10 unread messages per conversation using LATERAL to cap work per row.
    sql = <<~SQL.squish
      SELECT c.id AS conversation_id, COUNT(m.id)::integer AS unread_count
      FROM conversations c
      LEFT JOIN LATERAL (
        SELECT id
        FROM messages
        WHERE messages.conversation_id = c.id
          AND messages.message_type = #{incoming_type}
          AND messages.created_at > COALESCE(c.agent_last_seen_at, to_timestamp(0))
          AND (messages.content_attributes->>'read') IS DISTINCT FROM 'true'
        ORDER BY messages.created_at DESC
        LIMIT 10
      ) m ON TRUE
      WHERE c.id IN (#{quoted_ids})
      GROUP BY c.id
    SQL

    connection.exec_query(sql).to_a.each_with_object({}) do |row, memo|
      unread_count = row['unread_count'].to_i
      memo[row['conversation_id']] = unread_count if unread_count.positive?
    end
  end

  def last_non_activity_messages_map(conversation_ids)
    return {} if conversation_ids.blank?

    connection = ActiveRecord::Base.connection
    quoted_ids = quoted_uuid_list(conversation_ids, connection)
    activity_type = Message.message_types[:activity]

    # Resolve latest non-activity message ids per conversation with LATERAL, then preload senders.
    sql = <<~SQL.squish
      SELECT c.id AS conversation_id, m.id AS message_id
      FROM conversations c
      LEFT JOIN LATERAL (
        SELECT messages.id
        FROM messages
        WHERE messages.conversation_id = c.id
          AND messages.message_type != #{activity_type}
        ORDER BY messages.created_at DESC, messages.id DESC
        LIMIT 1
      ) m ON TRUE
      WHERE c.id IN (#{quoted_ids})
        AND m.id IS NOT NULL
    SQL

    rows = connection.exec_query(sql).to_a
    return {} if rows.empty?

    message_ids = rows.map { |row| row['message_id'] }.compact.uniq
    messages_by_id = Message.unscoped.where(id: message_ids).includes(:sender).index_by(&:id)

    rows.each_with_object({}) do |row, memo|
      message = messages_by_id[row['message_id']]
      memo[row['conversation_id']] = message if message
    end
  end

  def quoted_uuid_list(ids, connection = ActiveRecord::Base.connection)
    ids.map { |id| connection.quote(id) }.join(', ')
  end

  def labels_by_title
    label_indexes[:by_title]
  end

  def labels_by_id
    label_indexes[:by_id]
  end

  def label_indexes
    @label_indexes ||= begin
      all_labels = Label.all.to_a
      {
        by_title: all_labels.index_by { |label| label.title.to_s.downcase },
        by_id: all_labels.index_by { |label| label.id.to_s }
      }
    end
  end

  def conversations_pagination_meta
    current_page = @conversations.respond_to?(:current_page) ? @conversations.current_page : 1
    per_page = @conversations.respond_to?(:limit_value) ? @conversations.limit_value : @conversations.size
    total = @conversations.respond_to?(:total_count) ? @conversations.total_count : @conversations.size
    total_pages = per_page.to_i.positive? ? (total.to_f / per_page.to_i).ceil : 1
    total_pages = 1 if total_pages < 1

    {
      total_count: @conversations_count,
      current_page: current_page,
      per_page: per_page,
      total: total,
      total_pages: total_pages,
      has_next_page: current_page < total_pages,
      has_previous_page: current_page > 1
    }
  end

  def custom_attributes
    @conversation.custom_attributes = params.permit(custom_attributes: {})[:custom_attributes]
    @conversation.save!
    
    success_response(
      data: ConversationSerializer.serialize(
        @conversation,
        include_messages: false,
        include_labels: true,
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      ),
      message: 'Conversation custom attributes updated successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to update custom attributes',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  public
  def destroy
    authorize @conversation, :destroy?
    begin
      ::DeleteObjectJob.perform_now(@conversation, Current.user, request.ip)
    rescue ActiveRecord::RecordNotFound => e
      # Some async/extension callbacks can raise RecordNotFound after the row is already deleted.
      raise unless @conversation.destroyed?

      Rails.logger.warn(
        "Conversation #{params[:id]} deleted, but callback raised RecordNotFound: #{e.message}"
      )
    end
    
    success_response(
      data: { id: @conversation.id },
      message: 'Conversation deleted successfully'
    )
  end

  private

  def permitted_update_params
    # TODO: Move the other conversation attributes to this method and remove specific endpoints for each attribute
    params.permit(:priority)
  end

  def attachment_params
    params.permit(:page)
  end

  def update_last_seen_on_conversation(last_seen_at, update_assignee)
    # rubocop:disable Rails/SkipsModelValidations
    @conversation.update_column(:agent_last_seen_at, last_seen_at)
    @conversation.update_column(:assignee_last_seen_at, last_seen_at) if update_assignee.present?
    # rubocop:enable Rails/SkipsModelValidations
  end

  def set_conversation_status
    @conversation.status = params[:status]
    @conversation.snoozed_until = parse_date_time(params[:snoozed_until].to_s) if params[:snoozed_until]
  end

  def assign_conversation
    @conversation.assignee = current_user
    @conversation.save!
  end

  def conversation
    @conversation ||= resolve_conversation_with_includes(params[:id])
    raise ActiveRecord::RecordNotFound if @conversation.nil?

    # 🔒 PROTEÇÃO: Autorizar apenas se inbox existir
    # Se inbox não existir, autorizar a conversa diretamente (conversas podem existir sem inbox/channel)
    if @conversation.inbox.present?
      authorize @conversation.inbox, :show?
    else
      authorize @conversation, :show?
    end
  end

  def resolve_conversation_with_includes(conversation_param)
    return nil if conversation_param.blank?

    if uuid_format?(conversation_param)
      find_conversation_by_uuid_with_includes(conversation_param)
    else
      find_conversation_by_display_id_with_includes(conversation_param)
    end
  end

  def find_conversation_by_uuid_with_includes(uuid)
    Conversation.all
           .includes(:pipeline_items => [:pipeline, :pipeline_stage, :stage_movements])
           .find_by(id: uuid) ||
      Conversation.all
             .includes(:pipeline_items => [:pipeline, :pipeline_stage, :stage_movements])
             .find_by(uuid: uuid)
  end

  def find_conversation_by_display_id_with_includes(display_id)
    Conversation.all
           .includes(:pipeline_items => [:pipeline, :pipeline_stage, :stage_movements])
           .find_by!(display_id: display_id)
  end

  def inbox
    return if params[:inbox_id].blank?

    @inbox = Inbox.all.find(params[:inbox_id])
    authorize @inbox, :show?
  end

  def contact
    return if params[:contact_id].blank?

    @contact = Contact.all.find(params[:contact_id])
  end

  def contact_inbox
    @contact_inbox = build_contact_inbox

    # fallback for the old case where we do look up only using source id
    # In future we need to change this and make sure we do look up on combination of inbox_id and source_id
    # and deprecate the support of passing only source_id as the param
    # Fallback: look up contact_inbox by source_id
    if @contact_inbox.blank? && params[:source_id].present?
      @contact_inbox = ::ContactInbox.joins(:inbox)
                                     .where(source_id: params[:source_id])
                                     .all
                                     .first
      raise ActiveRecord::RecordNotFound if @contact_inbox.nil?
    end
    
    authorize @contact_inbox.inbox, :show? if @contact_inbox.present?
  rescue ActiveRecord::RecordNotUnique
    error_response(
      ApiErrorCodes::RESOURCE_ALREADY_EXISTS,
      'source_id should be unique',
      status: :unprocessable_entity
    )
  end

  def build_contact_inbox
    return if @inbox.blank? || @contact.blank?

    ContactInboxBuilder.new(
      contact: @contact,
      inbox: @inbox,
      source_id: params[:source_id],
      hmac_verified: hmac_verified?
    ).perform
  end

  def conversation_finder
    @conversation_finder ||= ConversationFinder.new(Current.user, params)
  end

  def assignee?
    @conversation.assignee_id? && Current.user == @conversation.assignee
  end

  def dispatch_messages_read_event
    # NOTE: Use old `agent_last_seen_at`, so we reference messages received after that
    Rails.configuration.dispatcher.dispatch(Events::Types::MESSAGES_READ, Time.zone.now, conversation: @conversation,
                                                                                         last_seen_at: @conversation.agent_last_seen_at)
  end
end

Api::V1::ConversationsController.prepend_mod_with('Api::V1::ConversationsController')
