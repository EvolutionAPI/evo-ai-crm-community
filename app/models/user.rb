# == Schema Information
#
# Table name: users
#
#  id                     :uuid             not null, primary key
#  availability           :integer          default(0)
#  confirmation_sent_at   :datetime
#  confirmation_token     :string
#  confirmed_at           :datetime
#  consumed_timestep      :integer
#  current_sign_in_at     :datetime
#  current_sign_in_ip     :string
#  custom_attributes      :jsonb
#  display_name           :string
#  email                  :string
#  email_otp_attempts     :integer          default(0)
#  email_otp_secret       :string
#  email_otp_sent_at      :datetime
#  encrypted_password     :string           default(""), not null
#  failed_mfa_attempts    :integer          default(0)
#  last_mfa_failure_at    :datetime
#  last_sign_in_at        :datetime
#  last_sign_in_ip        :string
#  message_signature      :text
#  mfa_confirmed_at       :datetime
#  mfa_method             :integer          default(0), not null
#  name                   :string           not null
#  otp_backup_codes       :text             default([]), is an Array
#  otp_required_for_login :boolean          default(FALSE), not null
#  otp_secret             :string
#  provider               :string           default("email"), not null
#  pubsub_token           :string
#  remember_created_at    :datetime
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  sign_in_count          :integer          default(0), not null
#  tokens                 :json
#  type                   :string
#  ui_settings            :jsonb
#  uid                    :string           default(""), not null
#  unconfirmed_email      :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
# Indexes
#
#  index_users_on_email                   (email)
#  index_users_on_email_otp_sent_at       (email_otp_sent_at)
#  index_users_on_mfa_method              (mfa_method)
#  index_users_on_otp_required_for_login  (otp_required_for_login)
#  index_users_on_pubsub_token            (pubsub_token) UNIQUE
#  index_users_on_reset_password_token    (reset_password_token) UNIQUE
#  index_users_on_uid_and_provider        (uid,provider) UNIQUE
#
class User < ApplicationRecord
  # Evolution Reference Model - managed by evo-auth-service
  # This model serves only as a reference to sync data from evo-auth-service
  
  # Removed all validations and authentication logic - handled by evo-auth-service
  include Pubsubable
  include Rails.application.routes.url_helpers
  include Reportable
  include Avatarable
  include UserAttributeHelpers

  # Role relationships (synced from evo-auth-service)
  has_many :user_roles, dependent: :destroy_async
  has_many :roles, through: :user_roles

  # Evolution-specific relationships only
  has_many :assigned_conversations, foreign_key: 'assignee_id', class_name: 'Conversation', dependent: :nullify, inverse_of: :assignee
  has_many :csat_survey_responses, foreign_key: 'assigned_agent_id', dependent: :nullify, inverse_of: :assigned_agent
  has_many :conversation_participants, dependent: :destroy_async
  has_many :participating_conversations, through: :conversation_participants, source: :conversation
  has_many :inbox_members, dependent: :destroy_async
  has_many :inboxes, through: :inbox_members, source: :inbox
  has_many :messages, as: :sender, dependent: :nullify
  has_many :custom_filters, dependent: :destroy_async
  has_many :dashboard_apps, dependent: :nullify
  has_many :mentions, dependent: :destroy_async
  has_many :notes, dependent: :nullify
  has_many :notification_settings, dependent: :destroy_async
  has_many :notification_subscriptions, dependent: :destroy_async
  has_many :user_tours, dependent: :destroy
  has_many :notifications, dependent: :destroy_async
  has_many :team_members, dependent: :destroy_async
  has_many :teams, through: :team_members

  # Cache fields for display purposes only
  scope :order_by_full_name, -> { order(:name) }

  def conversations
    assigned_conversations
  end

  def confirmed?
    confirmed_at.present?
  end

  def name
    read_attribute(:name) || display_name || email
  end

  # Sync data from evo-auth-service when needed
  def sync_from_evo_auth!
    return unless id.present?
    
    user_data = EvoAuthService.new.get_user(id)
    return unless user_data
    
    update_columns(
      name: user_data['name'],
      email: user_data['email'],
      confirmed_at: user_data['confirmed_at'] ? Time.parse(user_data['confirmed_at']) : nil
    )
  end
  has_many :teams, through: :team_members
  has_many :created_pipelines, class_name: 'Pipeline', foreign_key: 'created_by_id', dependent: :nullify, inverse_of: :created_by
  has_many :assigned_pipeline_items, class_name: 'PipelineItem', foreign_key: 'assigned_by_id', dependent: :nullify,
                                             inverse_of: :assigned_by
  has_many :stage_movements, foreign_key: 'moved_by_id', dependent: :nullify, inverse_of: :moved_by
  # rubocop:disable Rails/HasManyOrHasOneDependent
  # we are handling this in `remove_macros` callback
  has_many :macros, foreign_key: 'created_by_id', inverse_of: :created_by
  # rubocop:enable Rails/HasManyOrHasOneDependent

  before_validation :set_password_and_uid, on: :create
  after_destroy :remove_macros

  scope :order_by_full_name, -> { order('lower(name) ASC') }

  before_validation do
    self.email = email.try(:downcase)
  end

  def send_devise_notification(notification, *)
    devise_mailer.send(notification, self, *).deliver_later
  end

  def set_password_and_uid
    self.uid = email
  end

  def assigned_inboxes
    # Admins and users granted `conversations.read_all` (resolved once per request
    # into Current by EvoAuthConcern#set_current_user_from_auth_data — NOT via the
    # CRM `has_permission?` stub) see every inbox. `Current.evo_can_read_all_inboxes`
    # is nil outside a request (jobs); nil is treated as false here.
    return Inbox.all if administrator? || Current.evo_can_read_all_inboxes
    # Opt-in restriction: a user with no inbox_member assignment still sees all
    # inboxes (zero rupture on upgrade). Restriction kicks in from the 1st assignment.
    return Inbox.all if inbox_members.empty?

    inboxes
  end

  def serializable_hash(options = nil)
    super(options).merge(confirmed: confirmed?)
  end

  def available_name
    name.presence || email
  end

  def push_event_data
    {
      id: id,
      name: name,
      available_name: available_name,
      avatar_url: avatar_url,
      type: 'user',
      availability_status: availability_status,
      thumbnail: avatar_url
    }
  end

  def webhook_data
    {
      id: id,
      name: name,
      email: email,
      type: 'user'
    }
  end

  def will_save_change_to_email?
    mutations_from_database.changed?('email')
  end

  def self.from_email(email)
    find_by(email: email&.downcase)
  end

  private

  def remove_macros
    macros.personal.destroy_all
  end
end

User.include_mod_with('Concerns::User')
