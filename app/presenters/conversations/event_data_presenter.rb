class Conversations::EventDataPresenter < SimpleDelegator
  # Case-sensitive: Postgres renders uuid lower-case and ConversationSerializer indexes
  # by `label.id.to_s`, so an upper-case id tag resolves to no chip over REST. Matching
  # that keeps both paths agreeing on which chips exist.
  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  DEFAULT_LABEL_COLOR = '#1f93ff'.freeze

  # `include_labels_data: false` is the webhook egress — see PushDataHelper.
  def push_data(include_labels_data: true)
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
      **(include_labels_data ? { labels_data: push_labels_data } : {}),
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

  # `labels` stays a list of titles: the same hash is the webhook body, so changing
  # its type is a silent breaking change. A tag resolving to no Label row is dropped,
  # matching ConversationSerializer, so REST and realtime agree on which chips exist.
  def push_labels_data
    tags = label_list.map { |tag| tag.to_s.strip }.reject(&:blank?)
    return [] if tags.empty?

    by_title, by_id = label_indexes_for(tags)

    tags.filter_map do |tag|
      label = by_title[tag.downcase] || by_id[tag]
      next if label.nil?

      { id: label.id, title: label.title, color: label_color(label) }
    end.uniq { |label| label[:id] }
  end

  # The front drops an incoming label with no colour, so a blank one would leave the
  # chip invisible until a reload. The fallback is the column default.
  def label_color(label)
    label.color.presence || DEFAULT_LABEL_COLOR
  end

  # One query per broadcast, never one per label. Resolves in the same round trip
  # the two legacy shapes the REST path already tolerates: a tag holding the Label
  # PK instead of the title, and casing that predates the downcase hook on Label.
  def label_indexes_for(tags)
    scope = Label.where('LOWER(labels.title) IN (?)', tags.map(&:downcase))
    ids = tags.grep(UUID_FORMAT)
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
    # between evolution, evolution_go, whatsapp_cloud, etc.
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
