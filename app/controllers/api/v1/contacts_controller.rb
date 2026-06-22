class Api::V1::ContactsController < Api::V1::BaseController
  include Sift
  
  sort_on :email, type: :string
  sort_on :name, internal_name: :order_on_name, type: :scope, scope_params: [:direction]
  sort_on :phone_number, type: :string
  sort_on :last_activity_at, internal_name: :order_on_last_activity_at, type: :scope, scope_params: [:direction]
  sort_on :created_at, internal_name: :order_on_created_at, type: :scope, scope_params: [:direction]
  sort_on :company, internal_name: :order_on_company_name, type: :scope, scope_params: [:direction]
  sort_on :city, internal_name: :order_on_city, type: :scope, scope_params: [:direction]
  sort_on :country, internal_name: :order_on_country_name, type: :scope, scope_params: [:direction]

  require_permissions({
                        index: 'contacts.read',
                        show: 'contacts.read',
                        create: 'contacts.create',
                        update: 'contacts.update',
                        destroy: 'contacts.delete',
                        search: 'contacts.read',
                        filter: 'contacts.read',
                        active: 'contacts.read',
                        contactable_inboxes: 'contacts.read',
                        destroy_custom_attributes: 'contacts.update',
                        avatar: 'contacts.update',
                        import: 'contacts.import',
                        export: 'contacts.export',
                        companies: 'contacts.read',
                        companies_list: 'contacts.read',
                        pipelines: 'contacts.read'
                      })

  before_action :fetch_contact, only: [:show, :update, :destroy, :avatar, :contactable_inboxes, :destroy_custom_attributes, :companies, :pipelines]
  before_action :set_include_contact_inboxes, only: [:index, :active, :search, :filter, :show, :update]

  def index
    @contacts = fetch_contacts(listable_contacts)

    # Use cached count to avoid expensive COUNT(*) queries on large datasets
    @contacts_count = Rails.cache.fetch(cache_key_for_contacts_count, expires_in: 1.minute) do
      listable_contacts.count
    end

    apply_pagination

    paginated_response(
      data: ContactSerializer.serialize_collection(@contacts, include_contact_inboxes: @include_contact_inboxes),
      collection: @contacts,
      message: 'Contacts retrieved successfully'
    )
  end

  def search
    if params[:q].blank?
      return error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        'Specify search string with parameter q',
        details: { field: 'q', message: 'is required for search' },
        status: :unprocessable_entity
      )
    end

    contacts = listable_contacts.where(
      'name ILIKE :search OR email ILIKE :search OR phone_number ILIKE :search OR contacts.identifier LIKE :search
        OR contacts.additional_attributes->>\'company_name\' ILIKE :search',
      search: "%#{params[:q].strip}%"
    )
    @contacts_count = contacts.count
    @contacts = fetch_contacts(contacts)

    apply_pagination

    paginated_response(
      data: ContactSerializer.serialize_collection(@contacts, include_contact_inboxes: @include_contact_inboxes),
      collection: @contacts,
      message: 'Contacts search completed successfully'
    )
  end

  def import
    if params[:import_file].blank?
      return error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        I18n.t('errors.contacts.import.failed'),
        details: { field: 'import_file', message: 'is required' },
        status: :unprocessable_entity
      )
    end

    ActiveRecord::Base.transaction do
      import = DataImport.all.create!(data_type: 'contacts')
      import.import_file.attach(params[:import_file])
    end

    success_response(data: {}, message: 'Import started successfully', status: :ok)
  end

  def export
    column_names = params['column_names']
    filter_params = { :payload => params.permit!['payload'], :label => params.permit!['label'] }
    Account::ContactsExportJob.perform_later(Current.user.id, column_names, filter_params)
    success_response(data: {}, message: I18n.t('errors.contacts.export.success'), status: :ok)
  end

  # returns online contacts
  def active
    contacts = Contact.where(id: ::OnlineStatusTracker
                  .get_available_contact_ids)
    @contacts_count = contacts.count
    @contacts = fetch_contacts(contacts)

    apply_pagination

    paginated_response(
      data: ContactSerializer.serialize_collection(@contacts, include_contact_inboxes: @include_contact_inboxes),
      collection: @contacts,
      message: 'Active contacts retrieved successfully'
    )
  end

  def show
    success_response(
      data: ContactSerializer.serialize(@contact, include_contact_inboxes: @include_contact_inboxes, include_companies: true),
      message: 'Contact retrieved successfully'
    )
  end

  def filter
    result = ::Contacts::FilterService.new(nil, Current.user, params.permit!).perform
    contacts = result[:contacts]
    @contacts_count = result[:count]
    @contacts = fetch_contacts(contacts)

    apply_pagination

    paginated_response(
      data: ContactSerializer.serialize_collection(@contacts, include_contact_inboxes: @include_contact_inboxes),
      collection: @contacts,
      message: 'Contacts filtered successfully'
    )
  rescue CustomExceptions::CustomFilter::InvalidAttribute,
         CustomExceptions::CustomFilter::InvalidOperator,
         CustomExceptions::CustomFilter::InvalidQueryOperator,
         CustomExceptions::CustomFilter::InvalidValue => e
    error_response(
      ApiErrorCodes::INVALID_PARAMETER,
      'Invalid filter parameter',
      details: { message: e.message },
      status: :unprocessable_entity
    )
  end

  def contactable_inboxes
    @all_contactable_inboxes = Contacts::ContactableInboxesService.new(contact: @contact).get
    @contactable_inboxes = @all_contactable_inboxes.select { |contactable_inbox| policy(contactable_inbox[:inbox]).show? }

    # EVO-1551 round 4 — B3 fix.
    # `source_id` for WhatsApp/SMS/Email/Twilio is literally the contact's
    # phone/email (see Contacts::ContactableInboxesService). We cannot mask
    # in place because the frontend echoes the value back to
    # `POST /conversations`. The conversations controller accepts
    # `contact_id + inbox_id` alone — `ContactInboxBuilder` regenerates the
    # source_id server-side. So when the agent's masking predicate is on,
    # we strip the source_id for any channel NOT explicitly whitelisted as
    # safe. Default-deny means a future channel that exposes PII through
    # source_id is stripped automatically until someone audits it.
    strip_source_id = ContactPiiMasker.should_mask?

    contactable_inboxes = @contactable_inboxes.map do |contactable_inbox|
      inbox = contactable_inbox[:inbox]
      source_id = contactable_inbox[:source_id]
      source_id = nil if strip_source_id && !safe_to_expose_source_id?(inbox)

      InboxSerializer.serialize(inbox, include_channel: true).merge(
        available: true,
        can_create_conversation: true,
        source_id: source_id
      )
    end

    success_response(
      data: contactable_inboxes,
      message: 'Contactable inboxes retrieved successfully'
    )
  end

  # EVO-1551 round 4 — B3 helper.
  # Allowlist of channel types whose `source_id` is NOT PII and that the
  # frontend genuinely needs to round-trip. Default-deny: any new channel
  # is treated as PII-bearing until explicitly audited and added here.
  #   - Api / WebWidget / FacebookPage: source_id is a SecureRandom UUID.
  #   - Telegram: source_id is the opaque Telegram user id.
  #   - Instagram: source_id is the IG user id (no phone embedded).
  #   - Whatsapp without phone_number: BSUID-only contact — opaque id.
  def safe_to_expose_source_id?(inbox)
    case inbox.channel_type
    when 'Channel::Api', 'Channel::WebWidget', 'Channel::FacebookPage', 'Channel::Telegram', 'Channel::Instagram'
      true
    when 'Channel::Whatsapp'
      @contact.phone_number.blank?
    else
      false
    end
  end

  # TODO : refactor this method into dedicated contacts/custom_attributes controller class and routes
  def destroy_custom_attributes
    @contact.custom_attributes = @contact.custom_attributes.excluding(params[:custom_attributes])
    @contact.save!

    success_response(
      data: ContactSerializer.serialize(@contact, include_contact_inboxes: @include_contact_inboxes),
      message: 'Contact custom attributes updated successfully'
    )
  end

  def create
    return if render_invalid_create_labels_error

    ActiveRecord::Base.transaction do
      @contact = Contact.all.new(contact_create_params)
      @contact.save!
      process_company_associations
      @contact_inbox = build_contact_inbox
      process_avatar_from_url
    end

    success_response(
      data: {
        contact: ContactSerializer.serialize(@contact, include_contact_inboxes: true, include_companies: true),
        contact_inbox: if @contact_inbox
                         {
                           inbox: @contact_inbox.inbox,
                           source_id: @contact_inbox.source_id
                         }
                       end
      },
      message: 'Contact created successfully',
      status: :created
    )
  end

  def update
    Rails.logger.info "Contact update - permitted_params: #{permitted_params.inspect}"
    Rails.logger.info "Contact update - contact_update_params: #{contact_update_params.inspect}"
    @contact.assign_attributes(contact_update_params)
    @contact.save!
    process_company_associations
    @contact.reload
    Rails.logger.info "Contact after save - labels: #{@contact.labels.pluck(:name).inspect}"
    process_avatar_from_url

    success_response(
      data: ContactSerializer.serialize(@contact, include_contact_inboxes: @include_contact_inboxes, include_companies: true),
      message: 'Contact updated successfully'
    )
  end

  def destroy
    if ::OnlineStatusTracker.get_presence(
      'Contact', @contact.id
    )
      return error_response(
        ApiErrorCodes::OPERATION_NOT_ALLOWED,
        "Cannot delete contact '#{@contact.name.titleize}' while online",
        details: { contact_id: @contact.id, contact_name: @contact.name },
        status: :unprocessable_entity
      )
    end

    begin
      ActiveRecord::Base.transaction do
        cleanup_contact_dependent_records(@contact)
        @contact.destroy!
      end

      success_response(data:{}, message: 'Contact deleted successfully', status: :ok)
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::StatementInvalid => e
      if e.cause.is_a?(PG::ForeignKeyViolation) || e.message.include?('foreign key constraint')
        Rails.logger.error "Foreign key constraint violation while deleting contact #{@contact.id}: #{e.message}"
        error_response(
          ApiErrorCodes::OPERATION_NOT_ALLOWED,
          "Cannot delete contact '#{@contact.name.titleize}'. Contact has associated records that prevent deletion.",
          details: { contact_id: @contact.id, contact_name: @contact.name },
          status: :unprocessable_entity
        )
      else
        raise
      end
    rescue ActiveRecord::RecordNotDestroyed => e
      Rails.logger.error "Contact #{@contact.id} could not be destroyed: #{e.message}"
      error_response(
        ApiErrorCodes::OPERATION_NOT_ALLOWED,
        "Cannot delete contact '#{@contact.name.titleize}': #{e.record.errors.full_messages.join(', ')}",
        details: { contact_id: @contact.id, contact_name: @contact.name, errors: e.record.errors.full_messages },
        status: :unprocessable_entity
      )
    end
  end

  def avatar
    @contact.avatar.purge if @contact.avatar.attached?

    success_response(
      data: ContactSerializer.serialize(@contact, include_contact_inboxes: @include_contact_inboxes),
      message: 'Avatar removed successfully'
    )
  end

  def companies
    @companies = @contact.companies.preload(:labels, :company_contacts)

    success_response(
      data: ContactSerializer.serialize_collection(@companies),
      message: 'Contact companies retrieved successfully'
    )
  end

  def companies_list
    companies = Contact.all.resolved_contacts.where(type: 'company').select(:id, :name, :type, :location, :country_code).order(:name)

    success_response(
      data: companies.map { |company| { id: company.id, name: company.name } },
      message: 'Companies list retrieved successfully'
    )
  end

  def pipelines
    # Buscar todas as conversas do contato
    conversation_ids = @contact.conversations.pluck(:id)

    # Buscar pipeline items por contact_id ou conversation_id
    # Note: PipelineItem can belong to either a contact OR a conversation (never both)
    pipeline_items = PipelineItem
                       .includes(:pipeline, :pipeline_stage)
                       .where('contact_id = ? OR conversation_id IN (?)', @contact.id, conversation_ids)

    # Agrupar por pipeline
    pipelines_data = pipeline_items.group_by(&:pipeline).map do |pipeline, items|
      # Pegar o primeiro item de cada pipeline (assumindo que um contato está em apenas um estágio por pipeline)
      item = items.first
      stage = item.pipeline_stage

      {
        pipeline: {
          id: pipeline.id,
          name: pipeline.name,
          pipeline_type: pipeline.pipeline_type
        },
        stage: {
          id: stage.id,
          name: stage.name,
          color: stage.color,
          position: stage.position,
          stage_type: stage.stage_type
        },
        item: {
          id: item.id,
          item_id: item.contact_id || item.conversation_id,
          type: item.lead? ? 'lead' : 'deal',
          entered_at: item.entered_at&.to_i || item.created_at.to_i,
          notes: item.custom_fields&.dig('notes')
        }
      }
    end

    success_response(
      data: pipelines_data,
      message: 'Contact pipelines retrieved successfully'
    )
  end

  private

  # Cache key for contacts count, varies by query parameters that affect listable contacts
  def cache_key_for_contacts_count
    # Build a deterministic string based on filters that influence the count
    key_parts = [
      params[:type],
      params[:company_id],
      params[:labels]&.sort&.join(','),
      params[:q] # search query, if any
    ].compact.join('/')
    "contacts_count/#{key_parts.presence || 'all'}"
  end

  # TODO: Move this to a finder class
  def listable_contacts
    return @listable_contacts if @listable_contacts

    contacts_with_identity = Contact.all.resolved_contacts
    contacts_with_name = Contact.all.where("contacts.name IS NOT NULL AND BTRIM(contacts.name) <> ''")
    @listable_contacts = contacts_with_identity.or(contacts_with_name)

    if params[:type].present?
      @listable_contacts = @listable_contacts.where(type: params[:type])
    elsif params[:include_groups] != 'true'
      @listable_contacts = @listable_contacts.non_groups
    end

    @listable_contacts = @listable_contacts.for_company(params[:company_id]) if params[:company_id].present?

    @listable_contacts = @listable_contacts.tagged_with(params[:labels], any: true) if params[:labels].present?
    @listable_contacts
  end

  # TODO: Move this to a finder class
  def resolved_contacts
    return @resolved_contacts if @resolved_contacts

    @resolved_contacts = Contact.all.resolved_contacts

    @resolved_contacts = @resolved_contacts.where(type: params[:type]) if params[:type].present?

    @resolved_contacts = @resolved_contacts.for_company(params[:company_id]) if params[:company_id].present?

    @resolved_contacts = @resolved_contacts.tagged_with(params[:labels], any: true) if params[:labels].present?
    @resolved_contacts
  end

  def fetch_contacts(contacts)
    # Eager load conversations and pipeline items to avoid N+1 queries
    contacts_with_associations = filtrate(contacts)
                                   .includes([
                                               { avatar_attachment: [:blob] },
                                               { conversations: { pipeline_items: [:pipeline, :pipeline_stage] } }
                                             ])
                                   .preload(:labels, :companies, :contact_companies, :company_contacts)

    # Also preload pipeline items directly associated with contacts
    contact_ids = contacts_with_associations.map(&:id)
    PipelineItem.where(contact_id: contact_ids).includes(:pipeline, :pipeline_stage).load

    return contacts_with_associations.includes([{ contact_inboxes: [:inbox] }]) if @include_contact_inboxes

    contacts_with_associations
  end

  def build_contact_inbox
    return if params[:inbox_id].blank?

    inbox = (current_user&.assigned_inboxes || Inbox.all).find(params[:inbox_id])
    authorize inbox, :show?
    ContactInboxBuilder.new(
      contact: @contact,
      inbox: inbox,
      source_id: params[:source_id]
    ).perform
  end

  def permitted_params
    params.permit(:name, :identifier, :email, :phone_number, :avatar, :blocked, :avatar_url, :type, :tax_id, :website, :industry,
                  additional_attributes: {}, custom_attributes: {}, labels: [], company_ids: [])
  end

  def contact_custom_attributes
    return permitted_params[:custom_attributes] if permitted_params.key?(:custom_attributes)

    @contact.custom_attributes
  end

  def contact_additional_attributes
    return @contact.additional_attributes.merge(permitted_params[:additional_attributes]) if permitted_params[:additional_attributes]

    @contact.additional_attributes
  end

  def contact_update_params
    update_params = permitted_params.except(:custom_attributes, :avatar_url, :labels, :type, :company_ids)
                                    .merge({ custom_attributes: contact_custom_attributes })
                                    .merge({ additional_attributes: contact_additional_attributes })

    # Handle labels separately using the Labelable concern
    Rails.logger.info "Contact update - labels key exists: #{permitted_params.key?(:labels)}"
    Rails.logger.info "Contact update - labels value: #{permitted_params[:labels].inspect}"

    if permitted_params.key?(:labels)
      final_params = update_params.merge({ label_list: permitted_params[:labels] })
      Rails.logger.info "Contact update - final params with labels: #{final_params[:label_list].inspect}"
      final_params
    else
      Rails.logger.info 'Contact update - no labels key found, using update_params as is'
      update_params
    end
  end

  def contact_create_params
    create_params = permitted_params.except(:avatar_url, :company_ids, :labels)
    return create_params unless permitted_params.key?(:labels)

    create_params.merge({ label_list: normalized_contact_labels })
  end

  def normalized_contact_labels
    Array(permitted_params[:labels]).map(&:strip)
  end

  def invalid_contact_labels_payload?
    return false unless raw_labels_param_present?

    labels = raw_labels_param
    return true unless labels.is_a?(Array)

    labels.any? { |label| !label.is_a?(String) || label.strip.blank? }
  end

  def raw_labels_param_present?
    params.key?(:labels) || params.key?('labels')
  end

  def raw_labels_param
    params[:labels]
  end

  def render_invalid_create_labels_error
    return false unless invalid_contact_labels_payload?

    error_response(
      ApiErrorCodes::INVALID_PARAMETER,
      'Invalid labels payload',
      details: { field: 'labels', message: 'must be an array of non-empty strings' },
      status: :unprocessable_content
    )
    true
  end

  def process_company_associations
    # Only process for person contacts when company_ids is present
    return unless @contact.type == 'person' && permitted_params.key?(:company_ids)

    company_ids = permitted_params[:company_ids].compact.reject(&:blank?)

    # Get current company IDs
    current_company_ids = @contact.contact_companies.pluck(:company_id)

    # Calculate IDs to add and remove
    ids_to_add = company_ids - current_company_ids
    ids_to_remove = current_company_ids - company_ids

    # Remove associations that are no longer needed
    if ids_to_remove.any?
      @contact.contact_companies.where(company_id: ids_to_remove).destroy_all
      Rails.logger.info "Contact companies removed - IDs: #{ids_to_remove.inspect}"
    end

    # Add new associations
    if ids_to_add.any?
      # Validate companies exist and belong to current account
      companies_to_add = Contact.all.where(id: ids_to_add, type: 'company')

      companies_to_add.each do |company|
        @contact.contact_companies.create!(
          company: company
        )
      end

      Rails.logger.info "Contact companies added - IDs: #{companies_to_add.pluck(:id).inspect}"
    end

    Rails.logger.info "Contact companies final - IDs: #{@contact.contact_companies.reload.pluck(:company_id).inspect}"
  end

  def set_include_contact_inboxes
    @include_contact_inboxes = if params[:include_contact_inboxes].present?
                                 params[:include_contact_inboxes] == 'true'
                               else
                                 true
                               end
  end

  def fetch_contact
    @contact = Contact.all.includes(:labels, contact_inboxes: [:inbox]).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::CONTACT_NOT_FOUND,
      "Contact with ID '#{params[:id]}' not found",
      details: { contact_id: params[:id] },
      status: :not_found
    )
  end

  def process_avatar_from_url
    ::Avatar::AvatarFromUrlJob.perform_later(@contact, params[:avatar_url]) if params[:avatar_url].present?
  end

  def cleanup_contact_dependent_records(contact)
    conversation_ids = contact.conversations.pluck(:id)

    contact.conversations.find_each do |conversation|
      conversation.facebook_comment_moderations.destroy_all
      conversation.pipeline_items.destroy_all
      conversation.destroy!
    end

    PipelineItem.where(contact_id: contact.id).destroy_all

    contact.contact_inboxes.destroy_all
    contact.notes.destroy_all
    contact.csat_survey_responses.destroy_all
    contact.messages.destroy_all
  end

  def render_error(error, error_status)
    render json: error, status: error_status
  end

  def get_contact_pipelines(contact)
    # Buscar conversation IDs do contato
    conversation_ids = contact.conversations.pluck(:id)

    # Buscar pipeline items
    pipeline_items = PipelineItem
                       .includes(:pipeline, :pipeline_stage)
                       .where('contact_id = ? OR conversation_id IN (?)', contact.id, conversation_ids)

    # Agrupar por pipeline e retornar dados
    pipeline_items.group_by(&:pipeline).map do |pipeline, items|
      item = items.first
      stage = item.pipeline_stage

      {
        pipeline: {
          id: pipeline.id,
          name: pipeline.name,
          pipeline_type: pipeline.pipeline_type
        },
        stage: {
          id: stage.id,
          name: stage.name,
          color: stage.color,
          position: stage.position,
          stage_type: stage.stage_type
        },
        item: {
          id: item.id,
          item_id: item.contact_id || item.conversation_id,
          type: item.lead? ? 'lead' : 'deal',
          entered_at: item.entered_at&.to_i || item.created_at.to_i,
          notes: item.custom_fields&.dig('notes')
        }
      }
    end
  end
end
