module LabelActivityMessageHandler
  extend ActiveSupport::Concern

  UUID_LABEL_REGEX = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  private

  def create_label_added(user_name, labels = [])
    create_label_change_activity('added', user_name, labels)
  end

  def create_label_removed(user_name, labels = [])
    create_label_change_activity('removed', user_name, labels)
  end

  def create_label_change_activity(change_type, user_name, labels = [])
    return unless labels.size.positive?

    resolved = resolve_label_titles_for_activity(labels)
    content = I18n.t("conversations.activity.labels.#{change_type}", user_name: user_name, labels: resolved.join(', '))
    ::Conversations::ActivityMessageJob.perform_later(self, activity_message_params(content)) if content
  end

  # Defense-in-depth at the render boundary. The primary write paths that fed
  # UUIDs into `tags.name` were closed by EVO-1001 (`LabelConcern`, 2026-04-24)
  # and the automation flow (`ActionService#add_label` + StageAutomationService,
  # 2026-05-12). Several callers still skip those resolvers and can leak UUIDs
  # into `previous_changes[:label_list]`:
  #   * `BulkActionsJob#bulk_add_labels` and `#remove_labels` — bulk-action
  #     payloads carry UUIDs straight to `Labelable#add_labels`/`update!`.
  #   * `ActionService#remove_label` — operates on the conversation's existing
  #     `label_list`; if that list still contains legacy UUIDs the diff keeps
  #     them.
  #   * Direct writes in `app/controllers/api/v1/contacts_controller.rb`.
  #   * Legacy data persisted before the upstream fixes (orphan UUID-shaped
  #     `tags.name` rows survive a tagging removal).
  # Resolving here guarantees the activity message always shows a human-readable
  # title regardless of how the write reached `label_list`. If the label has
  # been deleted the original value is preserved so the message still renders.
  def resolve_label_titles_for_activity(labels)
    values = Array(labels).map(&:to_s).reject(&:empty?)
    uuids = values.grep(UUID_LABEL_REGEX)
    return values if uuids.empty?

    titles_by_id = Label.where(id: uuids).pluck(:id, :title).to_h.transform_keys(&:to_s)
    values.map { |v| titles_by_id[v] || v }
  end
end
