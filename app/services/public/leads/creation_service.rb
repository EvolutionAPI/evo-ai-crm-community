# frozen_string_literal: true

class Public::Leads::CreationService
  def initialize(account: nil, lead_params:)
    @lead_params = lead_params
    @errors = []
  end

  def perform
    ActiveRecord::Base.transaction do
      validate_required_params!
      validate_pipeline_and_stage!

      @contact = find_or_create_contact
      @pipeline_item = create_pipeline_item

      publish_events

      {
        success: true,
        contact: @contact,
        pipeline_item: @pipeline_item
      }
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "Public Leads API: Validation error - #{e.message}"
    { success: false, error: e.record.errors.full_messages.join(', '), errors: e.record.errors.full_messages }
  rescue StandardError => e
    Rails.logger.error "Public Leads API: Error in CreationService - #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    { success: false, error: e.message }
  end

  private

  def validate_required_params!
    # Validate contact required fields
    if contact_params[:name].blank?
      @errors << 'contact.name is required'
    end

    if contact_params[:email].blank?
      @errors << 'contact.email is required'
    elsif !valid_email?(contact_params[:email])
      @errors << 'contact.email must be a valid email address'
    end

    # Validate deal required fields
    if deal_params[:pipeline_id].blank?
      @errors << 'deal.pipeline_id is required'
    end

    if deal_params[:stage_id].blank?
      @errors << 'deal.stage_id is required'
    end

    raise StandardError, @errors.join(', ') if @errors.any?
  end

  def validate_pipeline_and_stage!
    @pipeline = Pipeline.find_by(id: deal_params[:pipeline_id])
    raise StandardError, 'Pipeline not found' unless @pipeline

    # Validate stage belongs to pipeline
    @pipeline_stage = @pipeline.pipeline_stages.find_by(id: deal_params[:stage_id])
    raise StandardError, 'Stage not found or does not belong to this pipeline' unless @pipeline_stage
  end

  def find_or_create_contact
    # Try to find existing contact by email
    contact = Contact.find_by(email: contact_params[:email])

    if contact
      # Update contact with new information if provided
      update_attrs = {}
      update_attrs[:name] = contact_params[:name] if contact_params[:name].present?

      # Handle phone number update - only if it's different from current
      if contact_params[:phone_number].present?
        normalized_phone = normalize_phone_number(contact_params[:phone_number])
        
        # Only update if phone is different from current
        if contact.phone_number != normalized_phone
          # Validate phone doesn't belong to another contact
          validate_phone_ownership!(normalized_phone, contact)
          update_attrs[:phone_number] = normalized_phone
        end
      end

      # Update additional_attributes with company if provided
      if contact_params[:company].present?
        contact.additional_attributes ||= {}
        contact.additional_attributes['company'] = contact_params[:company]
        update_attrs[:additional_attributes] = contact.additional_attributes
      end

      # Merge contact custom attributes if provided (B14.06 context-driven mapping).
      # This path is anonymous (public form/leads API), and a contact is matched
      # purely by email — so anyone who knows an existing contact's email could
      # otherwise clobber its attributes. Write additively: only fill keys that
      # are currently blank, never overwrite values the contact already holds.
      if contact_params[:custom_attributes].present?
        contact.custom_attributes ||= {}
        additive = contact_params[:custom_attributes].to_h.reject do |key, _|
          contact.custom_attributes[key].present?
        end
        if additive.any?
          contact.custom_attributes.merge!(additive)
          update_attrs[:custom_attributes] = contact.custom_attributes
        end
      end

      contact.update!(update_attrs) if update_attrs.any?

      Rails.logger.info "Public Leads API: Found existing contact #{contact.id} for email #{contact_params[:email]}"
    else
      # Validate phone doesn't belong to another contact before creating
      if contact_params[:phone_number].present?
        normalized_phone = normalize_phone_number(contact_params[:phone_number])
        validate_phone_ownership!(normalized_phone, nil)
      end

      # Create new contact
      contact_attributes = {
        name: contact_params[:name],
        email: contact_params[:email],
        phone_number: normalize_phone_number(contact_params[:phone_number]),
        additional_attributes: {},
        custom_attributes: contact_params[:custom_attributes].presence&.to_h || {}
      }

      # Add company to additional_attributes if provided
      contact_attributes[:additional_attributes]['company'] = contact_params[:company] if contact_params[:company].present?

      contact = Contact.create!(contact_attributes)

      Rails.logger.info "Public Leads API: Created new contact #{contact.id} - #{contact.email}"
    end

    contact
  end

  def create_pipeline_item
    # Prepare custom_fields with metadata
    combined_custom_fields = custom_fields_params.to_h.merge(
      'lead_source' => 'public_api',
      'lead_metadata' => metadata_params.to_h
    ).compact

    # Create deal title if not provided
    deal_title = deal_params[:title].presence || "Lead - #{@contact.name}"

    # Add value to custom_fields if provided
    combined_custom_fields['value'] = deal_params[:value] if deal_params[:value].present?

    # Create pipeline_item directly linked to contact (no conversation needed for leads)
    pipeline_item = @pipeline.pipeline_items.create!(
      contact: @contact,
      conversation: nil,
      pipeline_stage: @pipeline_stage,
      entered_at: Time.current,
      custom_fields: combined_custom_fields
    )

    Rails.logger.info "Public Leads API: Created lead #{pipeline_item.id} for contact #{@contact.id} " \
                      "in pipeline #{@pipeline.name}, stage #{@pipeline_stage.name}"

    pipeline_item
  end

  def publish_events
    # Events are automatically published by model callbacks (Wisper)
    # No manual publishing needed as Contact and PipelineItem
    # have after_create callbacks that publish events
    Rails.logger.info 'Public Leads API: Events published via model callbacks'
  end

  def validate_phone_ownership!(phone_number, current_contact)
    return if phone_number.blank?

    # Find if phone number exists in another contact
    existing_contact = Contact.find_by(phone_number: phone_number)

    # If phone exists and belongs to a DIFFERENT contact, raise error
    if existing_contact && existing_contact != current_contact
      raise StandardError, "Phone number #{phone_number} is already registered to another contact (#{existing_contact.email})"
    end
  end

  def normalize_phone_number(phone)
    return nil if phone.blank?

    # Canonicalize to the same form WhatsApp resolves to (Brazilian nono dígito,
    # MX/AR extra digit) via the shared normalizer — a faithful port of Evolution
    # API's createJid. This keeps the leads API in lockstep with the inbound
    # WhatsApp path so the same person never lands as two contacts.
    phone = Whatsapp::PhoneNumberNormalizer.to_e164(phone)

    # Validate E.164 format: +[1-9]\d{1,14}
    unless phone.present? && phone.match?(/\A\+[1-9]\d{1,14}\z/)
      raise StandardError, "Phone number must be in E.164 format (+[country][number]). Example: +5511999998888"
    end

    phone
  end

  def valid_email?(email)
    email.to_s.match?(URI::MailTo::EMAIL_REGEXP)
  end

  def contact_params
    @lead_params[:contact] || {}
  end

  def deal_params
    @lead_params[:deal] || {}
  end

  def custom_fields_params
    @lead_params[:custom_fields] || {}
  end

  def metadata_params
    @lead_params[:metadata] || {}
  end
end

