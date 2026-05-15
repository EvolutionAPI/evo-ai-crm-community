# == Schema Information
#
# Table name: pipelines
#
#  id            :uuid             not null, primary key
#  config        :jsonb
#  custom_fields :jsonb            not null
#  description   :text
#  is_active     :boolean          default(TRUE), not null
#  is_default    :boolean          default(FALSE), not null
#  name          :string           not null
#  pipeline_type :string           default("custom"), not null
#  visibility    :integer          default("private")
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  created_by_id :uuid             not null
#
# Indexes
#
#  index_pipelines_on_created_by_id      (created_by_id)
#  index_pipelines_on_custom_fields      (custom_fields) USING gin
#  index_pipelines_on_is_default_unique  (is_default) WHERE (is_default = true)
#  index_pipelines_on_name               (name) UNIQUE
#
class Pipeline < ApplicationRecord
  VALID_TYPES = %w[sales support onboarding custom marketing].freeze

  belongs_to :created_by, class_name: 'User'

  has_many :pipeline_stages, -> { order(:position) }, dependent: :destroy, inverse_of: :pipeline
  has_many :pipeline_items, dependent: :destroy
  has_many :conversations, through: :pipeline_items
  has_many :pipeline_service_definitions, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :pipeline_type, inclusion: { in: VALID_TYPES }

  enum visibility: { private: 0, team: 1, public: 2 }, _prefix: :visibility

  scope :active, -> { where(is_active: true) }
  scope :default, -> { where(is_default: true) }
  scope :accessible_by, lambda { |user|
    where(visibility: :public)
      .or(where(created_by: user))
      .or(where(is_default: true))
  }

  before_validation :set_default_custom_fields
  before_save :ensure_single_default_per_account, if: :is_default?
  after_update :cleanup_removed_attributes_from_items

  def add_conversation(conversation, stage = nil, user = nil)
    stage ||= pipeline_stages.first
    return false unless stage

    pipeline_items.create!(
      conversation: conversation,
      pipeline_stage: stage,
      assigned_by: user
    )
  end

  def add_contact(contact, stage = nil, user = nil)
    stage ||= pipeline_stages.first
    return false unless stage

    pipeline_items.create!(
      contact: contact,
      pipeline_stage: stage,
      assigned_by: user
    )
  end
  
  def item_count
    pipeline_items.count
  end

  def stage_counts
    pipeline_stages.left_joins(:pipeline_items)
                   .group(:id, :name)
                   .count('pipeline_items.id')
  end

  def push_event_data
    {
      id: id,
      name: name,
      pipeline_type: pipeline_type,
      visibility: visibility,
      is_active: is_active,
      created_by: created_by.push_event_data
    }
  end

  private

  def ensure_single_default_per_account
    # Desativa outros pipelines default quando este for ativado
    Pipeline.where(is_default: true)
            .where.not(id: id)
            .update_all(is_default: false)
  end

  def set_default_custom_fields
    self.custom_fields = {} if custom_fields.blank?
    # Ensure attributes is always an array
    self.custom_fields['attributes'] ||= []
    # Normalize: keep only attributes array, remove any other keys
    self.custom_fields = { 'attributes' => custom_fields['attributes'] }
  end

  def cleanup_removed_attributes_from_items
    return unless saved_change_to_custom_fields?

    old_value, new_value = saved_change_to_custom_fields
    old_attributes = (old_value&.dig('attributes') || []).map(&:to_s)
    new_attributes = (new_value&.dig('attributes') || []).map(&:to_s)
    
    # Find attributes that were removed
    removed_attributes = old_attributes - new_attributes
    
    return if removed_attributes.empty?

    # Clean up removed attributes from all pipeline items
    cleanup_attributes_from_items(removed_attributes)
  end

  def cleanup_attributes_from_items(attribute_keys)
    return if attribute_keys.empty?

    pipeline_items.find_each do |item|
      next if item.custom_fields.blank?

      updated_fields = item.custom_fields.dup
      changed = false

      attribute_keys.each do |key|
        if updated_fields.key?(key)
          updated_fields.delete(key)
          changed = true
        end
      end

      if changed
        item.update_column(:custom_fields, updated_fields) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end

end
