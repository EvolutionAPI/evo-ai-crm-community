# == Schema Information
#
# Table name: macros
#
#  id            :uuid             not null, primary key
#  actions       :jsonb            not null
#  name          :string           not null
#  visibility    :integer          default("personal")
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  created_by_id :uuid
#  updated_by_id :uuid
#
class Macro < ApplicationRecord
  include Rails.application.routes.url_helpers

  belongs_to :created_by,
             class_name: :User, optional: true, inverse_of: :macros
  belongs_to :updated_by,
             class_name: :User, optional: true
  has_many_attached :files

  enum visibility: { personal: 0, global: 1 }

  validate :json_actions_format

  ACTIONS_ATTRS = %w[send_message add_label assign_team assign_agent mute_conversation change_status remove_label remove_assigned_team
                     resolve_conversation snooze_conversation change_priority send_email_transcript send_attachment
                     add_private_note send_webhook_event].freeze

  def set_visibility(user, params)
    visibility_value = params[:visibility]
    
    if visibility_value.present?
      normalized_value = visibility_value.to_s.downcase.strip
      self.visibility = normalized_value if Macro.visibilities.key?(normalized_value)
    end
    
    self.visibility = :personal if user.agent?
  end

  def self.with_visibility(user, _params)
    records = Macro.global
    records = records.or(personal.where(created_by_id: user.id))
    records.order(:id)
  end

  def self.current_page(params)
    params[:page] || 1
  end

  def file_base_data
    files.map do |file|
      {
        id: file.id,
        macro_id: id,
        file_type: file.content_type,
        file_url: BlobUrlOptions.with_scoped_url_options { url_for(file) },
        blob_id: file.blob_id,
        filename: file.filename.to_s
      }
    end
  end

  private

  def json_actions_format
    return if actions.blank?

    attributes = actions.map { |obj, _| obj['action_name'] }
    actions = attributes - ACTIONS_ATTRS

    errors.add(:actions, "Macro execution actions #{actions.join(',')} not supported.") if actions.any?
  end
end

