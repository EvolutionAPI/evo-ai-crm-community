class Conversations::EventDataPresenter < SimpleDelegator
  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

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
      labels_data: push_labels_data,
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

  # CRM-155: `labels` stays a list of titles because `push_data` is also the
  # webhook body delivered to customer integrations — changing its type is a
  # silent breaking change. `labels_data` is additive and carries what the
  # realtime consumers need (id + title + color), so a label arriving over the
  # WebSocket no longer lands on the screen colourless.
  def push_labels_data
    tags = label_list.map { |tag| tag.to_s.strip }.reject(&:blank?)
    return [] if tags.empty?

    by_title, by_id = label_indexes_for(tags)

    tags.filter_map do |tag|
      label = by_title[tag.downcase] || by_id[tag]
      next if label.nil?

      { id: label.id, title: label.title, color: label.color }
    end
  end

  # One query per broadcast, never one per label. Legacy rows may still hold the
  # Label PK instead of the title, so both are resolved in the same round trip.
  def label_indexes_for(tags)
    ids = tags.grep(UUID_FORMAT)
    scope = Label.where(title: tags.map(&:downcase))
    scope = scope.or(Label.where(id: ids)) if ids.any?
    records = scope.to_a

    [records.index_by { |label| label.title.to_s.downcase }, records.index_by { |label| label.id.to_s }]
  end

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
