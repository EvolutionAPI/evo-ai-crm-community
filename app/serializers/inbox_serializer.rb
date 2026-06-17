# frozen_string_literal: true

# InboxSerializer - Optimized serialization for Inbox resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   InboxSerializer.serialize(@inbox, include_channel: true)
#
module InboxSerializer
  extend self

  # Serialize single Inbox with optimized field selection
  #
  # @param inbox [Inbox] Inbox to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_channel Include channel details
  # @option options [Boolean] :include_portal Include portal details
  # @option options [Boolean] :include_members Include team members
  #
  # @return [Hash] Serialized inbox ready for Oj
  #
  def serialize(inbox, include_channel: false, include_portal: false, include_members: false)
    # 🔒 SECURITY: hmac_token is excluded from as_json to prevent exposure in public APIs
    # It will be conditionally added later only for administrators
    result = inbox.as_json(
      only: [:id, :channel_id, :name, :display_name, :channel_type, :greeting_enabled,
             :greeting_message, :greeting_message_template_id, :enable_email_collect, :csat_survey_enabled,
             :enable_auto_assignment, :working_hours_enabled, :out_of_office_message,
             :out_of_office_message_template_id,
             :timezone, :allow_messages_after_resolved, :auto_assignment_config,
             :business_name, :portal_id,
             :sender_name_type, :additional_attributes, :csat_config,
             :lock_to_single_conversation, :default_conversation_status, :callback_webhook_url],
      methods: [:avatar_url]
    )

    # Include working_hours (weekly_schedule)
    result['working_hours'] = inbox.weekly_schedule if inbox.respond_to?(:weekly_schedule)

    # Timestamps
    result['created_at'] = inbox.created_at.to_i
    result['updated_at'] = inbox.updated_at.to_i

    # Include channel-specific fields
    if inbox.channel.present?
      # Provider (used by WhatsApp and other channels)
      result['provider'] = inbox.channel.provider if inbox.channel.respond_to?(:provider)

      # Live channel health (EVO-1674): state enums + timestamps only, never
      # tokens or provider payloads.
      health = Channels::ConnectionStateResolver.call(inbox.channel)
      result['connection_state'] = health[:state]
      result['health_source'] = health[:source]
      result['last_sync'] = health[:last_sync]&.to_i
      result['reauthorization_required'] = health[:reauthorization_required]

      # WhatsApp-specific data required by channel settings screens
      if inbox.whatsapp?
        result['provider_config'] = inbox.channel.try(:provider_config)
        result['provider_connection'] = inbox.channel.try(:provider_connection_data)
      end

      # API Channel specific fields
      if inbox.api?
        result['hmac_mandatory'] = inbox.channel.hmac_mandatory
        result['webhook_url'] = inbox.channel.webhook_url
        result['inbox_identifier'] = inbox.channel.identifier
        result['additional_attributes'] = inbox.channel.additional_attributes
        result['hmac_token'] = inbox.channel.hmac_token if Current.user&.role == 'administrator'
      end

      # SendGrid specific fields
      # 🔒 SECURITY: never expose api_key / api_key_encrypted; only signal presence
      if inbox.sendgrid?
        result['from_email'] = inbox.channel.from_email
        result['from_name'] = inbox.channel.from_name
        result['reply_to'] = inbox.channel.reply_to
        result['sender_domain'] = inbox.channel.sender_domain
        result['api_key_present'] = inbox.channel.api_key.present?
        result['webhook_registration_status'] = inbox.channel.webhook_registration_status
      end

      # WebWidget specific fields
      if inbox.web_widget?
        result['website_url'] = inbox.channel.website_url
        result['widget_color'] = inbox.channel.widget_color
        result['welcome_title'] = inbox.channel.welcome_title
        result['welcome_tagline'] = inbox.channel.welcome_tagline
        result['web_widget_script'] = inbox.channel.web_widget_script
        result['website_token'] = inbox.channel.website_token
        result['selected_feature_flags'] = inbox.channel.selected_feature_flags
        result['reply_time'] = inbox.channel.reply_time
        result['locale'] = inbox.channel.locale
        result['pre_chat_form_enabled'] = inbox.channel.pre_chat_form_enabled
        result['pre_chat_form_options'] = inbox.channel.pre_chat_form_options
        result['continuity_via_email'] = inbox.channel.continuity_via_email
        result['hmac_mandatory'] = inbox.channel.hmac_mandatory
        result['hmac_token'] = inbox.channel.hmac_token if Current.user&.role == 'administrator'
      end

      # Include full channel if requested
      # 🔒 SECURITY: Exclude hmac_token and api_key_encrypted from channel serialization to prevent exposure
      if include_channel
        channel_except = [:created_at, :updated_at, :hmac_token]
        channel_except << :api_key_encrypted if inbox.channel.respond_to?(:api_key_encrypted)
        channel_data = inbox.channel.as_json(except: channel_except)
        # Only include hmac_token if user is administrator
        if Current.user&.role == 'administrator' && inbox.channel.respond_to?(:hmac_token)
          channel_data['hmac_token'] = inbox.channel.hmac_token
        end
        result['channel'] = channel_data
      end
    end

    # Include portal
    if include_portal && inbox.portal.present?
      result['portal'] = {
        id: inbox.portal.id,
        name: inbox.portal.name,
        slug: inbox.portal.slug
      }
    end

    # Include members
    if include_members
      result['members'] = inbox.members.map do |member|
        UserSerializer.serialize(member)
      end
    end

    result
  end

  # Serialize collection of Inboxes
  #
  # @param inboxes [Array<Inbox>, ActiveRecord::Relation]
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized inboxes
  #
  def serialize_collection(inboxes, **options)
    return [] unless inboxes

    inboxes.map { |inbox| serialize(inbox, **options) }
  end
end
