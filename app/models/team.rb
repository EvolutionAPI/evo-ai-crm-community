# == Schema Information
#
# Table name: teams
#
#  id                :uuid             not null, primary key
#  allow_auto_assign :boolean          default(TRUE)
#  description       :text
#  name              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#
#  index_teams_on_name  (name) UNIQUE
#
class Team < ApplicationRecord
  has_many :team_members, dependent: :destroy_async
  has_many :members, through: :team_members, source: :user
  has_many :conversations, dependent: :nullify
  # EVO-2222: joins to `team`-visible pipelines shared with this team. Destroyed with
  # the team (synchronously, before the FK restrict bites) — a pipeline shared with
  # several teams just loses this one; if it was its only team it stays creator-only.
  has_many :pipeline_teams, dependent: :destroy

  validates :name,
            presence: { message: I18n.t('errors.validations.presence') },
            uniqueness: { case_sensitive: false },
            length: { maximum: 255 }
  validates :description, length: { maximum: 500 }

  before_validation do
    self.name = name.strip if attribute_present?('name')
  end

  # Adds multiple members to the team
  # @param user_ids [Array<Integer>] Array of user IDs to add as members
  # @return [Array<User>] Array of newly added members
  def add_members(user_ids)
    team_members_to_create = user_ids.map { |user_id| { user_id: user_id } }
    created_members = team_members.create!(team_members_to_create)
    added_users = created_members.filter_map(&:user)

    added_users
  end

  # Removes multiple members from the team
  # @param user_ids [Array<Integer>] Array of user IDs to remove
  # @return [void]
  def remove_members(user_ids)
    team_members.where(user_id: user_ids).destroy_all
  end

  def messages
    Message.where(conversation_id: conversations.pluck(:id))
  end

  def reporting_events
    ReportingEvent.where(conversation_id: conversations.pluck(:id))
  end

  def push_event_data
    {
      id: id,
      name: name
    }
  end
end

