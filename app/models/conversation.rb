# == Schema Information
#
# Table name: conversations
#
#  id                     :uuid             not null, primary key
#  additional_attributes  :jsonb
#  agent_last_seen_at     :datetime
#  assignee_last_seen_at  :datetime
#  cached_label_list      :text
#  contact_last_seen_at   :datetime
#  custom_attributes      :jsonb
#  first_reply_created_at :datetime
#  identifier             :string
#  last_activity_at       :datetime         not null
#  priority               :integer
#  snoozed_until          :datetime
#  status                 :integer          default("open"), not null
#  uuid                   :uuid             not null
#  waiting_since          :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  assignee_id            :uuid
#  contact_id             :uuid
#  contact_inbox_id       :uuid
#  display_id             :integer          not null
#  inbox_id               :uuid             not null
#  team_id                :uuid
#
# Indexes
#
#  conv_inbid_stat_asgnid_idx                            (inbox_id,status,assignee_id)
#  index_conversations_on_assignee_id                    (assignee_id)
#  index_conversations_on_assignee_status_last_activity  (assignee_id,status,last_activity_at DESC NULLS LAST)
#  index_conversations_on_contact_id                     (contact_id)
#  index_conversations_on_contact_inbox_id               (contact_inbox_id)
#  index_conversations_on_display_id                     (display_id) UNIQUE
#  index_conversations_on_first_reply_created_at         (first_reply_created_at)
#  index_conversations_on_inbox_id                       (inbox_id)
#  index_conversations_on_inbox_status_last_activity     (inbox_id,status,last_activity_at DESC NULLS LAST)
#  index_conversations_on_priority                       (priority)
#  index_conversations_on_status                         (status)
#  index_conversations_on_status_and_priority            (status,priority)
#  index_conversations_on_status_last_activity           (status,last_activity_at DESC NULLS LAST)
#  index_conversations_on_team_id                        (team_id)
#  index_conversations_on_uuid                           (uuid) UNIQUE
#  index_conversations_on_waiting_since                  (waiting_since)
#
class Conversation < ApplicationRecord
  include Labelable
  include LlmFormattable
  include AssignmentHandler
  include AutoAssignmentHandler
  include ActivityMessageHandler
  include UrlHelper
  include SortHandler
  include PushDataHelper
  include ConversationMuteHelpers
  include Wisper::Publisher

  validates :inbox_id, presence: true
  validates :contact_id, presence: true
  before_validation :validate_additional_attributes
  before_create :ensure_display_id
  validates :additional_attributes, jsonb_attributes_length: true
  validates :custom_attributes, jsonb_attributes_length: true
  validates :uuid, uniqueness: true
  validate :validate_referer_url

  enum status: { open: 0, resolved: 1, pending: 2, snoozed: 3 }
  enum priority: { low: 0, medium: 1, high: 2, urgent: 3 }

  scope :unassigned, -> { where(assignee_id: nil) }
  scope :assigned, -> { where.not(assignee_id: nil) }
  scope :assigned_to, ->(agent) { where(assignee_id: agent.id) }
  scope :unattended, -> { where(first_reply_created_at: nil).or(where.not(waiting_since: nil)) }
  scope :resolvable_not_waiting, lambda { |auto_resolve_after|
    return none if auto_resolve_after.to_i.zero?

    open.where('last_activity_at < ? AND waiting_since IS NULL', Time.now.utc - auto_resolve_after.minutes)
  }
  scope :resolvable_all, lambda { |auto_resolve_after|
    return none if auto_resolve_after.to_i.zero?

    open.where('last_activity_at < ?', Time.now.utc - auto_resolve_after.minutes)
  }
  scope :post_conversations, -> { where("additional_attributes->>'conversation_type' = ?", 'post') }
  scope :regular_conversations, -> { where("additional_attributes->>'conversation_type' IS NULL OR additional_attributes->>'conversation_type' != ?", 'post') }

  scope :last_user_message_at, lambda {
    joins(
      "INNER JOIN (#{last_messaged_conversations.to_sql}) AS grouped_conversations
      ON grouped_conversations.conversation_id = conversations.id"
    ).sort_on_last_user_message_at
  }

  belongs_to :inbox
  belongs_to :assignee, class_name: 'User', optional: true, inverse_of: :assigned_conversations
  belongs_to :contact
  belongs_to :contact_inbox
  belongs_to :team, optional: true

  has_many :mentions, dependent: :destroy_async
  # Interceptar associação messages para usar ScyllaDB quando habilitado
  has_many :messages, dependent: :destroy_async
  has_many :facebook_comment_moderations, dependent: :destroy_async, autosave: true
  has_one :csat_survey_response, dependent: :destroy_async
  has_many :conversation_participants, dependent: :destroy_async
  has_many :notifications, as: :primary_actor, dependent: :destroy_async
  has_many :attachments, through: :messages
  has_many :reporting_events, dependent: :destroy_async
  has_many :pipeline_items, dependent: :destroy_async
  has_many :pipelines, through: :pipeline_items

  before_save :ensure_snooze_until_reset
  before_create :ensure_display_id
  before_create :determine_conversation_status
  before_create :ensure_waiting_since

  after_update_commit :execute_after_update_commit_callbacks
  after_create_commit :notify_conversation_creation
  after_create_commit :load_attributes_created_by_db_triggers
  after_create_commit :publish_conversation_created
  after_create_commit :assign_to_default_pipeline
  after_update_commit :publish_conversation_updated
  after_destroy_commit :publish_conversation_deleted
  after_destroy_commit :sync_session_delete

  def auto_resolve_after
    nil
  end

  def can_reply?
    Conversations::MessageWindowService.new(self).can_reply?
  end

  def language
    additional_attributes&.dig('conversation_language')
  end

  # Be aware: The precision of created_at and last_activity_at may differ from Ruby's Time precision.
  # Our DB column (see schema) stores timestamps with second-level precision (no microseconds), so
  # if you assign a Ruby Time with microseconds, the DB will truncate it. This may cause subtle differences
  # if you compare or copy these values in Ruby, also in our specs
  # So in specs rely on to be_with(1.second) instead of to eq()
  # TODO: Migrate to use a timestamp with microsecond precision
  def last_activity_at
    self[:last_activity_at] || created_at
  end

  def last_incoming_message
    messages&.incoming&.last
  end

  def toggle_status
    # FIXME: implement state machine with aasm
    self.status = open? ? :resolved : :open
    self.status = :open if pending? || snoozed?
    save!
  end

  def toggle_priority(priority = nil)
    self.priority = priority.presence
    save!
  end

  def bot_handoff!
    open!
    dispatcher_dispatch(CONVERSATION_BOT_HANDOFF)
  end

  def unread_messages
    agent_last_seen_at.present? ? messages.created_since(agent_last_seen_at) : messages
  end

  def unread_incoming_messages
    unread_messages.incoming.last(10)
  end

  def cached_label_list_array
    (cached_label_list || '').split(',').map(&:strip)
  end

  def notifiable_assignee_change?
    return false unless saved_change_to_assignee_id?
    return false if assignee_id.blank?
    return false if self_assign?(assignee_id)

    true
  end

  def tweet?
    inbox.inbox_type == 'Twitter' && additional_attributes['type'] == 'tweet'
  end

  def recent_messages
    messages.chat.last(5)
  end

  def csat_survey_link
    "#{ENV.fetch('FRONTEND_URL', nil)}/survey/responses/#{uuid}"
  end

  def dispatch_conversation_updated_event(previous_changes = nil)
    dispatcher_dispatch(CONVERSATION_UPDATED, previous_changes)
  end

  def post_conversation?
    additional_attributes&.dig('conversation_type') == 'post'
  end

  def post_id
    additional_attributes&.dig('post_id')
  end

  def post_data
    additional_attributes&.dig('post_data') || {}
  end

  def is_boosted_post?
    additional_attributes&.dig('is_boosted') == true
  end

  private

  def ensure_display_id
    return if display_id.present?

    # Use a globally sequential display_id
    # This is thread-safe because we're using a database transaction
    max_display_id = self.class.maximum(:display_id) || 0
    self.display_id = max_display_id + 1
  end

  def execute_after_update_commit_callbacks
    notify_status_change
    create_activity
    notify_conversation_updation
  end

  def ensure_snooze_until_reset
    self.snoozed_until = nil unless snoozed?
  end

  def ensure_waiting_since
    self.waiting_since = created_at
  end

  def validate_additional_attributes
    self.additional_attributes = {} unless additional_attributes.is_a?(Hash)
  end

  def determine_conversation_status
    self.status = :resolved and return if contact.blocked?

    # Check if status was explicitly set (not just the database default)
    # We track this by checking if status was set before this callback runs
    # If status is 'open' and it's a new record, it's likely the DB default, so we should apply inbox default
    status_explicitly_set = @status_explicitly_set || false

    Rails.logger.info("[Conversation] determine_conversation_status - Status before: #{status}, explicitly_set: #{status_explicitly_set}, inbox_id: #{inbox_id}")

    # Always apply inbox default_conversation_status unless status was explicitly set
    # The database default is 'open', so if status is 'open' on a new record, it's likely the default
    unless status_explicitly_set
      inbox_default = inbox.default_conversation_status_value
      Rails.logger.info("[Conversation] determine_conversation_status - Applying inbox default: #{inbox_default} (inbox.default_conversation_status: #{inbox.default_conversation_status})")
      self.status = inbox_default
    else
      Rails.logger.info("[Conversation] determine_conversation_status - Status was explicitly set, keeping: #{status}")
    end

    Rails.logger.info("[Conversation] determine_conversation_status - Final status: #{status}")
  end

  # Helper method to mark status as explicitly set (used by builders and services)
  def status_explicitly_set!
    @status_explicitly_set = true
  end

  def notify_conversation_creation
    dispatcher_dispatch(CONVERSATION_CREATED)
  end

  def notify_conversation_updation
    return unless previous_changes.keys.present? && allowed_keys?

    dispatch_conversation_updated_event(previous_changes)
  end

  def list_of_keys
    %w[team_id assignee_id status snoozed_until custom_attributes label_list waiting_since first_reply_created_at
       priority]
  end

  def allowed_keys?
    (
      previous_changes.keys.intersect?(list_of_keys) ||
      (previous_changes['additional_attributes'].present? && previous_changes['additional_attributes'][1].keys.intersect?(%w[conversation_language]))
    )
  end

  def load_attributes_created_by_db_triggers
    # Display id is set via a trigger in the database
    # So we need to specifically fetch it after the record is created
    # We can't use reload because it will clear the previous changes, which we need for the dispatcher
    obj_from_db = self.class.find(id)
    self[:display_id] = obj_from_db[:display_id]
    self[:uuid] = obj_from_db[:uuid]
  end

  def notify_status_change
    {
      CONVERSATION_OPENED => -> { saved_change_to_status? && open? },
      CONVERSATION_RESOLVED => -> { saved_change_to_status? && resolved? },
      CONVERSATION_STATUS_CHANGED => -> { saved_change_to_status? },
      CONVERSATION_READ => -> { saved_change_to_contact_last_seen_at? },
      CONVERSATION_CONTACT_CHANGED => -> { saved_change_to_contact_id? }
    }.each do |event, condition|
      condition.call && dispatcher_dispatch(event, status_change)
    end
  end

  def dispatcher_dispatch(event_name, changed_attributes = nil)
    Rails.configuration.dispatcher.dispatch(event_name, Time.zone.now, conversation: self, notifiable_assignee_change: notifiable_assignee_change?,
                                                                       changed_attributes: changed_attributes,
                                                                       performed_by: Current.executed_by)
  end

  def conversation_status_changed_to_open?
    return false unless open?

    # saved_change_to_status? method only works in case of update
    true if previous_changes.key?(:id) || saved_change_to_status?
  end

  def create_label_change(user_name)
    return unless user_name

    previous_labels, current_labels = previous_changes[:label_list]
    return unless (previous_labels.is_a? Array) && (current_labels.is_a? Array)

    dispatcher_dispatch(CONVERSATION_UPDATED, previous_changes)

    create_label_added(user_name, current_labels - previous_labels)
    create_label_removed(user_name, previous_labels - current_labels)
  end

  def validate_referer_url
    return unless additional_attributes['referer']

    self['additional_attributes']['referer'] = nil unless url_valid?(additional_attributes['referer'])
  end

  # Wisper event publishers
  def publish_conversation_created
    publish(:conversation_created, data: { conversation: self, api_access_token: Current.api_access_token })
  end

  def publish_conversation_updated
    return unless saved_changes.any?

    publish(:conversation_updated, data: {
      conversation: self,
      changed_attributes: previous_changes,
      api_access_token: Current.api_access_token
    })
  end

  def publish_conversation_deleted
    publish(:conversation_deleted, data: { conversation: self, api_access_token: Current.api_access_token })
  end

  def sync_session_delete
    return unless inbox&.active_bot?

    AgentBots::SessionSyncService.delete_session_for_conversation(self)
  end

  def assign_to_default_pipeline
    default_pipeline = Pipeline.default.first
    unless default_pipeline
      Rails.logger.info "[Pipeline] No default pipeline found, skipping auto-assignment for conversation #{id}"
      return
    end

    # Verifica se já está no pipeline (prevenção de duplicatas)
    if default_pipeline.pipeline_items.exists?(conversation: self)
      Rails.logger.info "[Pipeline] Conversation #{id} already in default pipeline #{default_pipeline.id}, skipping"
      return
    end

    result = default_pipeline.add_conversation(self, nil, nil)
    if result
      Rails.logger.info "[Pipeline] Conversation #{id} auto-assigned to default pipeline #{default_pipeline.name}"
    else
      Rails.logger.warn "[Pipeline] Failed to auto-assign conversation #{id} to default pipeline #{default_pipeline.name} (no stages?)"
    end
  rescue StandardError => e
    Rails.logger.error "[Pipeline] Failed to add conversation #{id} to default pipeline: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    # Não falha a criação da conversation se pipeline assignment falhar
  end

  # Note: Database trigger removed - display_id is now generated in Ruby via before_create callback
end

Conversation.include_mod_with('Concerns::Conversation')
Conversation.prepend_mod_with('Conversation')
