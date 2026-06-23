# == Schema Information
#
# Table name: labels
#
#  id              :uuid             not null, primary key
#  color           :string           default("#1f93ff"), not null
#  description     :text
#  show_on_sidebar :boolean
#  title           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_labels_on_title  (title) UNIQUE
#
class Label < ApplicationRecord
  include RegexHelper
  include Events::Types

  validates :title,
            presence: { message: I18n.t('errors.validations.presence') },
            format: { with: UNICODE_CHARACTER_NUMBER_SPACE_HYPHEN_UNDERSCORE, allow_blank: true },
            uniqueness: true

  after_create_commit :dispatch_create_event
  after_update_commit :update_associated_models, :dispatch_update_event
  after_destroy_commit :dispatch_destroy_event
  default_scope { order(:title) }

  before_validation do
    next unless attribute_present?('title')
    
    if title.is_a?(String)
      stripped = title.strip
      self.title = stripped.present? ? stripped.downcase : nil
    end
  end

  def conversations
    Conversation.tagged_with(title)
  end

  def messages
    Message.where(conversation_id: conversations.pluck(:id))
  end

  def reporting_events
    ReportingEvent.where(conversation_id: conversations.pluck(:id))
  end

  # Number of records (contacts + conversations) currently tagged with this label.
  def usage_count
    self.class.usage_counts_for([title]).fetch(title, 0)
  end

  # Batched, N+1-free usage counts for a set of titles: { title => count }.
  def self.usage_counts_for(titles)
    names = Array(titles).compact
    return {} if names.empty?

    ActsAsTaggableOn::Tagging
      .joins(:tag)
      .where(taggings: { context: 'labels' }, tags: { name: names })
      .group('tags.name')
      .count
  end

  private

  def update_associated_models
    return unless title_previously_changed?

    Labels::UpdateJob.perform_later(title, title_previously_was)
  end

  def dispatch_create_event
    Rails.configuration.dispatcher.dispatch(LABEL_CREATED, Time.zone.now, label: self)
  end

  def dispatch_update_event
    Rails.configuration.dispatcher.dispatch(LABEL_UPDATED, Time.zone.now, label: self, saved_changes: saved_changes)
  end

  def dispatch_destroy_event
    Rails.configuration.dispatcher.dispatch(LABEL_DELETED, Time.zone.now, label: self)
  end
end
