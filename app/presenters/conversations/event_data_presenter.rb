class Conversations::EventDataPresenter < SimpleDelegator
  def push_data
    {
      additional_attributes: additional_attributes,
      can_reply: can_reply?,
      channel: inbox.try(:channel_type),
      contact_inbox: push_contact_inbox,
      id: id.to_s,
      display_id: display_id,
      inbox_id: inbox_id,
      messages: push_messages,
      labels: label_list,
      meta: push_meta,
      status: status,
      custom_attributes: custom_attributes,
      is_group: contact&.group? || false,
      snoozed_until: snoozed_until,
      unread_count: unread_incoming_messages_count,
      first_reply_created_at: first_reply_created_at,
      priority: priority,
      waiting_since: waiting_since.to_i,
      **push_timestamps
    }
  end

  private

  # EVO-1551 round 3 / CB-4: `contact_inbox: contact_inbox` previously dumped
  # the raw ActiveRecord model via `as_json`, which exposed `source_id` (the
  # WhatsApp JID embeds the phone number) on every conversation broadcast.
  # Audience here is mixed (admins + agents on inbox/account topics), so we
  # mask whenever the account flag is on regardless of `Current.user`. Keep
  # every other attribute intact to preserve the payload shape consumers
  # depend on; only `source_id` is rewritten.
  def push_contact_inbox
    return nil if contact_inbox.nil?
    return contact_inbox unless ContactPiiMasker.account_flag_enabled?

    contact_inbox.as_json.merge('source_id' => ContactPiiMasker.mask_identifier(contact_inbox.source_id))
  end

  def push_messages
    [messages.chat.last&.push_event_data].compact
  end

  def push_meta
    meta = {
      sender: contact.push_event_data,
      assignee: assignee&.push_event_data,
      team: team&.push_event_data,
      hmac_verified: contact_inbox&.hmac_verified
    }

    # Ensure inbox is loaded
    return meta unless inbox

    # Include channel type in meta
    meta[:channel] = inbox.channel_type if inbox.channel_type.present?

    # Include provider for WhatsApp channels so the frontend can differentiate
    # between evolution, evolution_go, whatsapp_cloud, baileys, etc.
    meta[:provider] = inbox.channel.provider if inbox.channel_type == 'Channel::Whatsapp'

    meta
  end

  def push_timestamps
    {
      agent_last_seen_at: agent_last_seen_at.to_i,
      contact_last_seen_at: contact_last_seen_at.to_i,
      last_activity_at: last_activity_at.to_i,
      timestamp: last_activity_at.to_i,
      created_at: created_at.to_i,
      updated_at: updated_at.to_f
    }
  end
end
Conversations::EventDataPresenter.prepend_mod_with('Conversations::EventDataPresenter')
