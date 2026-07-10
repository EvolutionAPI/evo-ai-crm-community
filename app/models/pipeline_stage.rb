# == Schema Information
#
# Table name: pipeline_stages
#
#  id               :uuid             not null, primary key
#  automation_rules :jsonb
#  color            :string           default("#3B82F6")
#  custom_fields    :jsonb            not null
#  name             :string           not null
#  position         :integer          not null
#  stage_type       :integer          default(0)
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  pipeline_id      :uuid             not null
#
# Indexes
#
#  index_pipeline_stages_on_custom_fields             (custom_fields) USING gin
#  index_pipeline_stages_on_pipeline_id               (pipeline_id)
#  index_pipeline_stages_on_pipeline_id_and_position  (pipeline_id,position) UNIQUE
#
class PipelineStage < ApplicationRecord
  belongs_to :pipeline
  has_many :pipeline_items, dependent: :destroy
  has_many :conversations, through: :pipeline_items
  has_many :stage_movements_from, class_name: 'StageMovement', foreign_key: 'from_stage_id', dependent: :destroy, inverse_of: :from_stage
  has_many :stage_movements_to, class_name: 'StageMovement', foreign_key: 'to_stage_id', dependent: :destroy, inverse_of: :to_stage

  # stage_type is an integer column (default 0). Without this enum the frontend's
  # string values ("active"/"completed"/"cancelled") were coerced via String#to_i to 0,
  # so a stage saved as "completed"/"cancelled" always silently reverted to "active".
  # The enum maps the strings to/from the integers so save + serialize round-trip.
  enum :stage_type, { active: 0, completed: 1, cancelled: 2 }, prefix: :stage

  validates :name, presence: true
  validates :position, presence: true, uniqueness: { scope: :pipeline_id }
  validates :color, format: { with: /\A#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})\z/, message: :invalid_hex_color }

  scope :ordered, -> { order(:position) }

  before_validation :set_default_automation_rules
  before_validation :set_default_custom_fields
  after_update :cleanup_removed_attributes_from_items
  before_destroy :reassign_conversations_to_first_stage

  def item_count
    pipeline_items.count
  end

  def next_stage
    pipeline.pipeline_stages.where('position > ?', position).order(:position).first
  end

  def previous_stage
    pipeline.pipeline_stages.where('position < ?', position).order(position: :desc).first
  end

  def push_event_data
    {
      id: id,
      name: name,
      position: position,
      color: color,
      stage_type: stage_type,
      item_count: item_count
    }
  end

  private

  def set_default_automation_rules
    self.automation_rules = {} if automation_rules.blank?
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

    # Clean up removed attributes from all pipeline items in this stage
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

  def reassign_conversations_to_first_stage
    return if pipeline_items.empty?

    first_stage = pipeline.pipeline_stages.where.not(id: id).order(:position).first
    return unless first_stage

    # Using update_all for bulk reassignment during stage deletion
    pipeline_items.update_all(pipeline_stage_id: first_stage.id) # rubocop:disable Rails/SkipsModelValidations
  end
end
