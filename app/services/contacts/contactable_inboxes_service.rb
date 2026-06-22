class Contacts::ContactableInboxesService
  pattr_initialize [:contact!]

  def get
    # Scope to the current user's accessible inboxes (admin/read_all/opt-in handled
    # by assigned_inboxes). Degrade to all inboxes when there is no resolvable user
    # (e.g. Pipelines::StageInactivityTargetResolver runs this in a background job).
    scope = Current.user&.assigned_inboxes || Inbox.all
    scope.filter_map { |inbox| get_contactable_inbox(inbox) }
  end

  private

  def get_contactable_inbox(inbox)
    case inbox.channel_type
    when 'Channel::TwilioSms'
      twilio_contactable_inbox(inbox)
    when 'Channel::Whatsapp'
      whatsapp_contactable_inbox(inbox)
    when 'Channel::Sms'
      sms_contactable_inbox(inbox)
    when 'Channel::Email'
      email_contactable_inbox(inbox)
    when 'Channel::Api'
      api_contactable_inbox(inbox)
    when 'Channel::WebWidget'
      website_contactable_inbox(inbox)
    when 'Channel::Telegram'
      telegram_contactable_inbox(inbox)
    end
  end

  def website_contactable_inbox(inbox)
    latest_contact_inbox = inbox.contact_inboxes.where(contact: @contact).last
    return unless latest_contact_inbox
    # FIXME : change this when multiple conversations comes in
    return if latest_contact_inbox.conversations.present?

    { source_id: latest_contact_inbox.source_id, inbox: inbox }
  end

  def api_contactable_inbox(inbox)
    latest_contact_inbox = inbox.contact_inboxes.where(contact: @contact).last
    source_id = latest_contact_inbox&.source_id || SecureRandom.uuid

    { source_id: source_id, inbox: inbox }
  end

  def email_contactable_inbox(inbox)
    return if @contact.email.blank?

    { source_id: @contact.email, inbox: inbox }
  end

  def whatsapp_contactable_inbox(inbox)
    return if @contact.phone_number.blank?

    # Remove the plus since thats the format 360 dialog uses
    { source_id: @contact.phone_number.delete('+'), inbox: inbox }
  end

  def sms_contactable_inbox(inbox)
    return if @contact.phone_number.blank?

    { source_id: @contact.phone_number, inbox: inbox }
  end

  def twilio_contactable_inbox(inbox)
    return if @contact.phone_number.blank?

    case inbox.channel.medium
    when 'sms'
      { source_id: @contact.phone_number, inbox: inbox }
    when 'whatsapp'
      { source_id: "whatsapp:#{@contact.phone_number}", inbox: inbox }
    end
  end

  def telegram_contactable_inbox(inbox)
    # Check if contact already has a Telegram contact_inbox
    existing_contact_inbox = inbox.contact_inboxes.where(contact: @contact).last
    if existing_contact_inbox
      # Reuse existing source_id (Telegram user ID)
      { source_id: existing_contact_inbox.source_id, inbox: inbox }
    else
      # Try to extract Telegram user ID from contact attributes
      # The identifier might be in format "tg_123456789" or just the username
      telegram_user_id = extract_telegram_user_id
      return nil unless telegram_user_id

      { source_id: telegram_user_id.to_s, inbox: inbox }
    end
  end

  def extract_telegram_user_id
    # First, check additional_attributes for social_telegram_user_id
    telegram_id = @contact.additional_attributes&.dig('social_telegram_user_id')
    return telegram_id if telegram_id.present?

    # Then, check identifier - it might be in format "tg_123456789"
    if @contact.identifier.present?
      # If identifier starts with "tg_", extract the ID
      if @contact.identifier.start_with?('tg_')
        return @contact.identifier.sub('tg_', '')
      end
      # If identifier is numeric, it might be the Telegram user ID
      return @contact.identifier if @contact.identifier.match?(/^\d+$/)
    end

    nil
  end
end
