# frozen_string_literal: true

# == Schema Information
#
# Table name: crm_forms
#
#  id                  :uuid             not null, primary key
#  appearance          :jsonb            not null
#  description         :text
#  fields              :jsonb            not null
#  name                :string(255)      not null
#  published           :boolean          default(FALSE), not null
#  routing_rules       :jsonb            not null
#  slug                :string(255)      not null
#  title               :string(255)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  default_pipeline_id :uuid             not null
#  default_stage_id    :uuid
#
# Indexes
#
#  index_crm_forms_on_fields         (fields) USING gin
#  index_crm_forms_on_published      (published)
#  index_crm_forms_on_routing_rules  (routing_rules) USING gin
#  index_crm_forms_on_slug           (slug) UNIQUE
#
# A lead-capture form (B14.01). Generic and single-tenant in Community; the
# per-tenant isolation (tenant_id + RLS) is layered on top in Enterprise.
#
# A form is NOT bound to a single pipeline: it carries a default pipeline/stage
# plus optional `routing_rules` that route a submission to a different
# pipeline/stage based on field answers (e.g. answer X -> Pipeline A).
class CrmForm < ApplicationRecord
  belongs_to :default_pipeline, class_name: 'Pipeline'
  belongs_to :default_stage, class_name: 'PipelineStage', optional: true

  FIELD_TYPES = %w[text email tel number textarea select checkbox].freeze
  # Maps a form field onto the contact attributes Public::Leads::CreationService expects.
  MAPPABLE    = %w[name email phone company].freeze
  ROUTING_OPS = %w[equals not_equals contains].freeze

  before_validation :generate_slug, on: :create

  validates :name, presence: true, length: { maximum: 255 }
  validates :slug, presence: true, uniqueness: true, length: { maximum: 255 },
                   format: { with: /\A[a-z0-9\-]+\z/, message: 'must be lowercase alphanumeric with dashes' }
  validate :validate_fields_schema
  validate :validate_routing_rules

  scope :published, -> { where(published: true) }

  # Public-facing heading: falls back to the internal name when no title is set.
  def display_title
    title.presence || name
  end

  # Resolve the destination [pipeline_id, stage_id] for a submission, applying the
  # first matching routing rule and falling back to the form's default.
  # @param answers [Hash] field_key => submitted value
  def resolve_destination(answers)
    rule = Array(routing_rules).find { |r| rule_matches?(r, answers) }

    if rule && rule['pipeline_id'].present?
      [rule['pipeline_id'], rule['stage_id'].presence || default_stage_id]
    else
      [default_pipeline_id, default_stage_id]
    end
  end

  private

  def rule_matches?(rule, answers)
    value  = answers[rule['field']].to_s
    target = rule['value'].to_s

    case rule['op']
    when 'equals'     then value.casecmp?(target)
    when 'not_equals' then !value.casecmp?(target)
    when 'contains'   then value.downcase.include?(target.downcase)
    else false
    end
  end

  def generate_slug
    return if slug.present?

    base = name.to_s.parameterize
    base = "form-#{SecureRandom.hex(4)}" if base.blank?

    candidate = base
    suffix = 2
    while CrmForm.exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end

    self.slug = candidate
  end

  def validate_fields_schema
    unless fields.is_a?(Array)
      errors.add(:fields, 'must be an array')
      return
    end

    fields.each_with_index do |field, idx|
      errors.add(:fields, "[#{idx}] must have a key") if field['key'].blank?

      errors.add(:fields, "[#{idx}] has invalid type '#{field['type']}'") if field['type'].present? && FIELD_TYPES.exclude?(field['type'])

      errors.add(:fields, "[#{idx}] has invalid maps_to '#{field['maps_to']}'") if field['maps_to'].present? && MAPPABLE.exclude?(field['maps_to'])
    end

    # CreationService requires a contact name + email, so the form must collect them.
    mapped = fields.filter_map { |f| f['maps_to'] }
    errors.add(:fields, 'must include a field mapped to email') if mapped.exclude?('email')
    errors.add(:fields, 'must include a field mapped to name')  if mapped.exclude?('name')
  end

  def validate_routing_rules
    unless routing_rules.is_a?(Array)
      errors.add(:routing_rules, 'must be an array')
      return
    end

    routing_rules.each_with_index do |rule, idx|
      errors.add(:routing_rules, "[#{idx}] has invalid op '#{rule['op']}'") if rule['op'].present? && ROUTING_OPS.exclude?(rule['op'])
      errors.add(:routing_rules, "[#{idx}] requires a pipeline_id") if rule['pipeline_id'].blank?
    end
  end
end
