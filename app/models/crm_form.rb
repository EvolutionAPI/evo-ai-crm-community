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

  # Contact custom-attribute where the public submission stamps the form slug(s) a
  # contact was captured through (EVO-2200). Single source of truth is the WRITER,
  # so a key rename there can't silently empty this read (or a hardcoded literal here).
  CAPTURE_FORMS_ATTRIBUTE = Public::Leads::CreationService::CAPTURE_FORMS_ATTRIBUTE

  # Pipeline items captured by this form via the public submission endpoint
  # (the submit stamps custom_fields.lead_metadata.form_slug). (B14.07)
  # Kept as the LEGACY read + the source of the deal (pipeline/stage) columns.
  def captured_leads
    PipelineItem.where("custom_fields -> 'lead_metadata' ->> 'form_slug' = ?", slug)
  end

  # EVO-2207: a captured lead is the CONTACT that filled the form, not the pipeline
  # item — deleting the kanban card must not erase attribution. Durable source is the
  # contact stamped with the slug (EVO-2200); we union legacy leads that only carry
  # form_slug on a pipeline item (captured before the stamp existed). Counts only
  # contacts that still EXIST (both sources), deduped, so the count never exceeds the
  # rows captured_lead_rows can render. Memoized: read twice per leads request.
  def captured_contact_ids
    @captured_contact_ids ||= begin
      stamped  = Contact.where('custom_attributes @> ?', stamped_containment).pluck(:id)
      via_item = Contact.where(id: captured_leads.select(:contact_id)).pluck(:id)
      (stamped + via_item).uniq
    end
  end

  # Ordered lead rows [{ contact:, item: }], one per contact, durable across item
  # deletion. `item` is nil for stamped-only / deleted-card leads (deal columns
  # degrade). The ORDER BY and the LIMIT both run in the DB, keyed on the SAME date
  # the endpoint serializes — COALESCE(most-recent matching item date, contact date) —
  # so a deleted-card lead sorts by its own date instead of being shoved past the cut
  # and vanishing again (EVO-2207 Alto 3). A LATERAL picks the most-recent matching
  # item per contact; nothing but the page is pulled into memory (Alto 2).
  def captured_lead_rows(limit: 200)
    contacts = Contact.find_by_sql([<<~SQL.squish, slug, stamped_containment, limit.to_i])
      SELECT c.*, li.item_id AS lead_item_id
      FROM contacts c
      LEFT JOIN LATERAL (
        SELECT pi.id AS item_id, pi.created_at AS item_created_at
        FROM pipeline_items pi
        WHERE pi.contact_id = c.id
          AND pi.custom_fields -> 'lead_metadata' ->> 'form_slug' = ?
        ORDER BY pi.created_at DESC
        LIMIT 1
      ) li ON TRUE
      WHERE c.custom_attributes @> ?
         OR li.item_id IS NOT NULL
      ORDER BY COALESCE(li.item_created_at, c.created_at) DESC, c.id DESC
      LIMIT ?
    SQL

    items = PipelineItem.includes(:pipeline, :pipeline_stage)
                        .where(id: contacts.filter_map { |c| c['lead_item_id'] })
                        .index_by(&:id)

    contacts.map { |contact| { contact: contact, item: items[contact['lead_item_id']] } }
  end

  # { slug => distinct-contact count } across both the durable and legacy sources.
  # Per-form (2 queries each): the forms list is small/paginated; correctness over a
  # single grouped query that couldn't dedup contacts present in both sources.
  def self.lead_counts_by_slug(slugs)
    return {} if slugs.blank?

    where(slug: slugs).each_with_object({}) do |form, acc|
      acc[form.slug] = form.captured_contact_ids.size
    end
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

  # jsonb containment probe for "this contact was stamped with our slug" — bind-safe
  # (`@>` with a JSON literal, not the `?` operator that clashes with AR placeholders).
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
