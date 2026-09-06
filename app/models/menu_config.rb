# frozen_string_literal: true

# == Schema Information
#
# Table name: menu_configs
#
#  id         :uuid             not null, primary key
#  payload    :jsonb            not null
#  scope      :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :uuid
#
# Indexes
#
#  index_menu_configs_on_scope  (scope) UNIQUE
#
class MenuConfig < ApplicationRecord
  SCOPES = %w[
    editor-menus
    dashboard-menu-items
    site-menu-items
  ].freeze

  belongs_to :user, optional: true

  validates :scope, presence: true, inclusion: { in: SCOPES }, uniqueness: true
  validate :validate_payload_shape

  def self.fetch_for(scope)
    find_by(scope: scope)&.payload
  end

  def self.upsert_for!(scope, payload, editor: nil)
    record = find_or_initialize_by(scope: scope)
    record.payload = payload || {}
    record.user = editor if editor
    record.save!
    record
  end

  private

  # payload deve ser um JSON object (hash) — os utils do frontend gravam arrays;
  # normalizamos para { items: [...] } quando chega um array cru.
  def validate_payload_shape
    return if payload.is_a?(Hash) || payload.is_a?(Array)

    errors.add(:payload, 'must be a JSON object or array')
  end
end
