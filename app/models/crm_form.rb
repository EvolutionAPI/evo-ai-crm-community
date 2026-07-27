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

  # Read from the writer so a key rename there can't silently empty this read (EVO-2200).
  CAPTURE_FORMS_ATTRIBUTE = Public::Leads::CreationService::CAPTURE_FORMS_ATTRIBUTE

  # Legacy source of a captured lead, and the source of the deal columns (B14.07).
  def captured_leads
    PipelineItem.where("custom_fields -> 'lead_metadata' ->> 'form_slug' = ?", slug)
  end

  # The leads endpoint takes no pagination params, so the ceiling lives here.
  MAX_LEAD_ROWS = 200

  # EVO-2207: a lead is the CONTACT, so it outlives its kanban card. UNION and not
  # `stamped OR legacy` — an OR across the two tables drops both indexes and scans all of
  # `contacts`. The FK on pipeline_items.contact_id makes a non-null id a contact.
  CAPTURED_CONTACT_IDS_SQL = <<~SQL.squish
    SELECT c.id FROM contacts c WHERE c.custom_attributes @> :stamp
    UNION
    SELECT pi.contact_id FROM pipeline_items pi
     WHERE pi.custom_fields -> 'lead_metadata' ->> 'form_slug' = :slug
       AND pi.contact_id IS NOT NULL
  SQL

  # Counted in SQL: plucking every id to call .size put each form's whole lead base in Ruby.
  def captured_leads_count
    @captured_leads_count ||= self.class.connection.select_value(
      self.class.sanitize_sql([<<~SQL.squish, { stamp: stamped_containment, slug: slug }])
        SELECT COUNT(*) FROM (#{CAPTURED_CONTACT_IDS_SQL}) captured
      SQL
    ).to_i
  end

  # [{ contact:, item: }], one row per contact with its most recent card, so a repeat
  # submitter is one lead and not three. ORDER BY and LIMIT run in the DB on the same
  # COALESCE the endpoint serializes: a deleted-card lead sorts by its own date instead
  # of being pushed past the cut and vanishing again.
  def captured_lead_rows(limit: MAX_LEAD_ROWS)
    binds = { stamp: stamped_containment, slug: slug, limit: limit.to_i.clamp(1, MAX_LEAD_ROWS) }

    contacts = Contact.find_by_sql([<<~SQL.squish, binds])
      WITH captured AS MATERIALIZED (#{CAPTURED_CONTACT_IDS_SQL})
      SELECT c.*, li.item_id AS lead_item_id
      FROM captured
      JOIN contacts c ON c.id = captured.id
      LEFT JOIN LATERAL (
        SELECT pi.id AS item_id, pi.created_at AS item_created_at
        FROM pipeline_items pi
        WHERE pi.contact_id = c.id
          AND pi.custom_fields -> 'lead_metadata' ->> 'form_slug' = :slug
        ORDER BY pi.created_at DESC
        LIMIT 1
      ) li ON TRUE
      ORDER BY COALESCE(li.item_created_at, c.created_at) DESC, c.id DESC
      LIMIT :limit
    SQL

    items = PipelineItem.includes(:pipeline, :pipeline_stage)
                        .where(id: contacts.filter_map { |c| c['lead_item_id'] })
                        .index_by(&:id)

    contacts.map { |contact| { contact: contact, item: items[contact['lead_item_id']] } }
  end

  # One query for the whole page: counting per form ran two each, and pageSize has no cap.
  def self.lead_counts_by_slug(slugs)
    return {} if slugs.blank?

    rows = connection.select_all(
      sanitize_sql([<<~SQL.squish, { attribute: CAPTURE_FORMS_ATTRIBUTE, slugs: Array(slugs) }])
        SELECT captured.slug, COUNT(*) AS lead_count FROM (
          SELECT s.slug, c.id
            FROM unnest(ARRAY[:slugs]::text[]) AS s(slug)
            JOIN contacts c
              ON c.custom_attributes @> jsonb_build_object(:attribute, jsonb_build_array(s.slug))
          UNION
          SELECT pi.custom_fields -> 'lead_metadata' ->> 'form_slug', pi.contact_id
            FROM pipeline_items pi
           WHERE pi.custom_fields -> 'lead_metadata' ->> 'form_slug' = ANY (ARRAY[:slugs]::text[])
             AND pi.contact_id IS NOT NULL
        ) captured
        GROUP BY captured.slug
      SQL
    )

    rows.each_with_object({}) { |row, acc| acc[row['slug']] = row['lead_count'].to_i }
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

  # `@>` with a JSON literal, not the `?` operator, which clashes with AR placeholders.
  def stamped_containment
    { CAPTURE_FORMS_ATTRIBUTE => [slug] }.to_json
  end

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
