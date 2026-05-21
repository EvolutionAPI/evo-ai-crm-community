module Labelable
  extend ActiveSupport::Concern

  included do
    acts_as_taggable_on :labels
  end

  # H2: diff label_list before/after and emit Wisper events for each
  # added/removed label so EvoFlow listeners can observe them. We only
  # call the contact-scoped publishers; for non-Contact tagged models
  # this concern is still safe because the methods are absent (publishers
  # check `respond_to?` before firing).
  def update_labels(labels = nil)
    before = label_list.to_a
    update!(label_list: labels)
    emit_label_change_events(before, label_list.to_a)
  end

  def add_labels(new_labels = nil)
    new_labels = Array(new_labels)
    before = label_list.to_a
    combined_labels = labels + new_labels
    update!(label_list: combined_labels)
    emit_label_change_events(before, label_list.to_a)
  end

  private

  def emit_label_change_events(before, after)
    return unless respond_to?(:publish_label_added, true) && respond_to?(:publish_label_removed, true)

    (after - before).each { |label_name| publish_label_added(label_name) }
    (before - after).each { |label_name| publish_label_removed(label_name) }
  end
end
