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
  # Standard contact fields a form field can target.
  MAPPABLE    = %w[name email phone company].freeze
  # Typed mapping kinds (flat schema: field['maps_to'] = kind, field['maps_to_key'] = key).
  MAP_KINDS   = %w[contact contact_attribute deal_value deal_attribute].freeze
  ROUTING_OPS = %w[equals not_equals contains].freeze

  before_validation :generate_slug, on: :create

  validates :name, presence: true, length: { maximum: 255 }
  validates :slug, presence: true, uniqueness: true, length: { maximum: 255 },
                   format: { with: /\A[a-z0-9\-]+\z/, message: 'must be lowercase alphanumeric with dashes' }
  validate :validate_fields_schema
  validate :validate_routing_rules
  validate :validate_default_destination

  scope :published, -> { where(published: true) }

  # Public-facing heading: falls back to the internal name when no title is set.
  def display_title
    title.presence || name
  end

  # Pipeline items captured by this form via the public submission endpoint
  # (the submit stamps custom_fields.lead_metadata.form_slug). (B14.07)
  def captured_leads
    PipelineItem.where("custom_fields -> 'lead_metadata' ->> 'form_slug' = ?", slug)
  end

  # One grouped query: { slug => count } for the given slugs.
  def self.lead_counts_by_slug(slugs)
    return {} if slugs.blank?

    PipelineItem.where("custom_fields -> 'lead_metadata' ->> 'form_slug' IN (?)", slugs)
                .group("custom_fields -> 'lead_metadata' ->> 'form_slug'").count
  end

  # Resolve a field's mapping into [bucket, key]. Handles both the legacy string
  # form (maps_to = 'name'|'email'|'phone'|'company') and the typed form
  # (maps_to = kind, maps_to_key = key). Returns nil when unmapped/invalid.
  #
  # Buckets: :contact (key in MAPPABLE), :contact_attribute, :deal_value, :deal_attribute.
  # This is the shared contract between the admin builder and the public submission:
  # every target the builder can configure is a target the submission can receive.
  def self.field_target(field)
    maps_to = field['maps_to'].to_s
    key     = field['maps_to_key'].to_s
    return nil if maps_to.blank?

    # Legacy: maps_to is itself a standard contact field.
    return [:contact, maps_to] if MAPPABLE.include?(maps_to)

    case maps_to
    when 'contact'           then [:contact, key] if MAPPABLE.include?(key)
    when 'contact_attribute' then [:contact_attribute, key] if key.present?
    when 'deal_value'        then [:deal_value, 'value']
    when 'deal_attribute'    then [:deal_attribute, key] if key.present?
    end
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

      errors.add(:fields, "[#{idx}] has an invalid mapping target") if field['maps_to'].present? && self.class.field_target(field).nil?
    end

    # CreationService requires a contact name + email, so the form must collect them.
    targets = fields.map { |f| self.class.field_target(f) }
    errors.add(:fields, 'must include a field mapped to contact email') unless targets.include?([:contact, 'email'])
    errors.add(:fields, 'must include a field mapped to contact name')  unless targets.include?([:contact, 'name'])
  end

  def validate_routing_rules
    unless routing_rules.is_a?(Array)
      errors.add(:routing_rules, 'must be an array')
      return
    end

    routing_rules.each_with_index do |rule, idx|
      errors.add(:routing_rules, "[#{idx}] has invalid op '#{rule['op']}'") if rule['op'].present? && ROUTING_OPS.exclude?(rule['op'])

      pipeline_id = rule['pipeline_id']
      if pipeline_id.blank?
        errors.add(:routing_rules, "[#{idx}] requires a pipeline_id")
        next
      end

      # A rule's destination must exist and be consistent, or every submission it
      # routes 422s inside CreationService — a published form capturing zero leads.
      pipeline = Pipeline.find_by(id: pipeline_id)
      if pipeline.nil?
        errors.add(:routing_rules, "[#{idx}] references a pipeline that does not exist")
        next
      end

      stage_id = rule['stage_id']
      if stage_id.present? && pipeline.pipeline_stages.where(id: stage_id).none?
        errors.add(:routing_rules, "[#{idx}] references a stage that does not belong to the pipeline")
      end
    end
  end

  # The default destination feeds every submission that no rule routes (and is
  # the stage fallback for rules without their own stage), so it gets the same
  # existence + membership guarantee. `default_pipeline` presence/existence is
  # already enforced by the (required) belongs_to; here we only need to confirm
  # the optional default stage actually belongs to that pipeline.
  def validate_default_destination
    return if default_stage_id.blank? || default_pipeline_id.blank?
    return if default_pipeline&.pipeline_stages&.where(id: default_stage_id)&.exists?

    errors.add(:default_stage, 'must belong to the default pipeline')
  end
end
