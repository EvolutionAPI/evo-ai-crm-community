# == Schema Information
#
# Table name: inboxes
#
#  id                                :uuid             not null, primary key
#  allow_messages_after_resolved     :boolean          default(TRUE)
#  auto_assignment_config            :jsonb
#  business_name                     :string
#  channel_type                      :string
#  csat_config                       :jsonb
#  csat_survey_enabled               :boolean          default(FALSE)
#  default_conversation_status       :string
#  display_name                      :string
#  email_address                     :string
#  enable_auto_assignment            :boolean          default(TRUE)
#  enable_email_collect              :boolean          default(TRUE)
#  greeting_enabled                  :boolean          default(FALSE)
#  greeting_message                  :string
#  lock_to_single_conversation       :boolean          default(FALSE), not null
#  name                              :string           not null
#  out_of_office_message             :string
#  sender_name_type                  :integer          default("friendly"), not null
#  timezone                          :string           default("UTC")
#  working_hours_enabled             :boolean          default(FALSE)
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  channel_id                        :uuid             not null
#  greeting_message_template_id      :uuid
#  out_of_office_message_template_id :uuid
#
# Indexes
#
#  index_inboxes_on_channel_id_and_channel_type  (channel_id,channel_type)
#  index_inboxes_on_default_conversation_status  (default_conversation_status)
#
class Inbox < ApplicationRecord
  include Reportable
  include Avatarable
  include OutOfOffisable
  include InstanceNameSanitizable

  # Not allowing characters:
  validates :name, presence: true
  validates :timezone, inclusion: { in: TZInfo::Timezone.all_identifiers }
  validates :out_of_office_message, length: { maximum: Limits::OUT_OF_OFFICE_MESSAGE_MAX_LENGTH }
  validates :greeting_message, length: { maximum: Limits::GREETING_MESSAGE_MAX_LENGTH }
  validate :ensure_valid_max_assignment_limit
  validate :validate_default_conversation_status

  before_validation :sanitize_instance_name_and_set_display_name

  belongs_to :channel, polymorphic: true, dependent: :destroy

  # has_many :c, dependent: :destroy_async # Campaign model doesn't exist
  has_many :contact_inboxes, dependent: :destroy_async
  has_many :contacts, through: :contact_inboxes

  has_many :inbox_members, dependent: :destroy_async
  has_many :members, through: :inbox_members, source: :user
  has_many :conversations, dependent: :destroy_async
  has_many :messages, dependent: :destroy_async

  has_one :agent_bot_inbox, dependent: :destroy_async
  has_one :agent_bot, through: :agent_bot_inbox
  has_many :webhooks, dependent: :destroy_async
  has_many :hooks, dependent: :destroy_async, class_name: 'Integrations::Hook'

  enum sender_name_type: { friendly: 0, professional: 1 }

  after_destroy :delete_round_robin_agents

  after_create_commit :dispatch_create_event
  after_update_commit :dispatch_update_event

  scope :order_by_name, -> { order('lower(name) ASC') }

  # Adds multiple members to the inbox
  # @param user_ids [Array<Integer>] Array of user IDs to add as members
  # @return [void]
  def add_members(user_ids)
    inbox_members.create!(user_ids.map { |user_id| { user_id: user_id } })
  end

  # Removes multiple members from the inbox
  # @param user_ids [Array<Integer>] Array of user IDs to remove
  # @return [void]
  def remove_members(user_ids)
    inbox_members.where(user_id: user_ids).destroy_all
  end

  # Sanitizes inbox name for balanced email provider compatibility
  # ALLOWS: /'._- and Unicode letters/numbers/emojis
  # REMOVES: Forbidden chars (\<>@") + spam-trigger symbols (!#$%&*+=?^`{|}~)
  def sanitized_name
    return default_name_for_blank_name if name.blank?

    sanitized = apply_sanitization_rules(name)
    sanitized.blank? && email? ? display_name_from_email : sanitized
  end

  def sms?
    channel_type == 'Channel::Sms'
  end

  def facebook?
    channel_type == 'Channel::FacebookPage'
  end

  def instagram?
    (facebook? || instagram_direct?) && channel.instagram_id.present?
  end

  def instagram_direct?
    channel_type == 'Channel::Instagram'
  end

  def web_widget?
    channel_type == 'Channel::WebWidget'
  end

  def api?
    channel_type == 'Channel::Api'
  end

  def email?
    channel_type == 'Channel::Email'
  end

  def twilio?
    channel_type == 'Channel::TwilioSms'
  end

  def twitter?
    channel_type == 'Channel::TwitterProfile'
  end

  def whatsapp?
    channel_type == 'Channel::Whatsapp'
  end

  def sendgrid?
    channel_type == 'Channel::Sendgrid'
  end

  def assignable_agents
    members.to_a
  end

  def active_bot?
    result = agent_bot_inbox&.active?
    Rails.logger.info "[Inbox] active_bot? - inbox_id: #{id}, agent_bot_inbox present?: #{agent_bot_inbox.present?}, agent_bot_inbox&.active?: #{agent_bot_inbox&.active?}, result: #{result}"
    result
  end

  def inbox_type
    channel&.name || 'Unknown'
  end

  def webhook_data
    {
      id: id,
      name: name
    }
  end

  def callback_webhook_url
    host = ENV.fetch('FRONTEND_URL', nil)
    case channel_type
    when 'Channel::TwilioSms'
      "#{host}/twilio/callback"
    when 'Channel::Sms'
      "#{host}/webhooks/sms/#{channel.phone_number.delete_prefix('+')}"
    when 'Channel::Line'
      "#{host}/webhooks/line/#{channel.line_channel_id}"
    when 'Channel::Whatsapp'
      host = ENV.fetch('INTERNAL_HOST_URL', nil) if channel&.use_internal_host?
      # Use global webhook if global verify token is configured
      if GlobalConfig.get_value('WP_VERIFY_TOKEN').present?
        "#{host}/webhooks/whatsapp"
      else
        # Fallback to phone-specific webhook
        "#{host}/webhooks/whatsapp/#{channel&.phone_number}"
      end
    end
  end

  def member_ids_with_assignment_capacity
    members.ids
  end

  # Returns the default conversation status for this inbox
  # Falls back to 'pending' if inbox has active bot and no default is set
  # Falls back to 'open' if no bot and no default is set
  def default_conversation_status_value
    Rails.logger.info("[Inbox] default_conversation_status_value - inbox_id: #{id}, default_conversation_status: #{default_conversation_status.inspect}, active_bot?: #{active_bot?}")

    return default_conversation_status.to_sym if default_conversation_status.present?

    # Legacy behavior: if inbox has active bot, default to pending
    return :pending if active_bot?

    # Default to open for new conversations
    :open
  end

  private

  def default_name_for_blank_name
    email? ? display_name_from_email : ''
  end

  def apply_sanitization_rules(name)
    name.gsub(/[\\<>@"!#$%&*+=?^`{|}~]/, '')            # Remove forbidden chars
        .gsub(/[\x00-\x1F\x7F]/, ' ')                   # Replace control chars with spaces
        .gsub(/\A[[:punct:]]+|[[:punct:]]+\z/, '')      # Remove leading/trailing punctuation
        .gsub(/\s+/, ' ')                               # Normalize spaces
        .strip
  end

  def display_name_from_email
    channel.email.split('@').first.parameterize.titleize
  end

  def dispatch_create_event
    return if ENV['ENABLE_INBOX_EVENTS'].blank?

    Rails.configuration.dispatcher.dispatch(INBOX_CREATED, Time.zone.now, inbox: self)
  end

  def dispatch_update_event
    return if ENV['ENABLE_INBOX_EVENTS'].blank?

    Rails.configuration.dispatcher.dispatch(INBOX_UPDATED, Time.zone.now, inbox: self, changed_attributes: previous_changes)
  end

  def ensure_valid_max_assignment_limit
  end

  def validate_default_conversation_status
    return if default_conversation_status.blank?

    valid_statuses = %w[open resolved pending snoozed]
    unless valid_statuses.include?(default_conversation_status)
      errors.add(:default_conversation_status, "must be one of: #{valid_statuses.join(', ')}")
    end
  end

  def delete_round_robin_agents
    ::AutoAssignment::InboxRoundRobinService.new(inbox: self).clear_queue
  end

  def check_channel_type?
    ['Channel::Email', 'Channel::Api', 'Channel::WebWidget'].include?(channel_type)
  end

  def sanitize_instance_name_and_set_display_name
    return if name.blank?

    # Se display_name não foi fornecido, usar o name original
    self.display_name = name if display_name.blank?

    # Sanitizar o name para uso como identificador usando método do concern
    self.name = sanitize_instance_name(name)
  end
end

Inbox.prepend_mod_with('Inbox')
Inbox.include_mod_with('Concerns::Inbox')
