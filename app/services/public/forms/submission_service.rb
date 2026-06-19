# frozen_string_literal: true

# Public::Forms::SubmissionService
#
# Handles an anonymous lead-capture form submission (B14.01): runs anti-spam
# checks, maps the submitted answers onto contact attributes, resolves the
# destination pipeline/stage from the form's routing rules, and delegates the
# actual contact + pipeline_item creation to Public::Leads::CreationService.
class Public::Forms::SubmissionService
  # Hidden field rendered by the public form; bots fill everything, humans never see it.
  HONEYPOT_FIELD = '_hp_url'

  def initialize(form:, params:)
    @form = form
    @params = params
  end

  def perform
    # Silently discard suspected spam without creating anything.
    return { success: true, skipped: true } if honeypot_triggered?

    answers = extract_answers
    missing = missing_required_fields(answers)
    return { success: false, errors: missing } if missing.any?

    pipeline_id, stage_id = resolve_destination(answers)

    Public::Leads::CreationService.new(
      lead_params: build_lead_params(answers, pipeline_id, stage_id)
    ).perform
  end

  private

  def submission
    @submission ||= (@params[:submission] || {}).to_h.with_indifferent_access
  end

  def honeypot_triggered?
    submission[HONEYPOT_FIELD].present?
  end

  # Answers keyed by field key, dropping the honeypot.
  def extract_answers
    submission.except(HONEYPOT_FIELD).to_h
  end

  def missing_required_fields(answers)
    Array(@form.fields).filter_map do |field|
      next unless field['required']

      "#{field['label'].presence || field['key']} is required" if answers[field['key']].to_s.blank?
    end
  end

  # Resolve [pipeline_id, stage_id], falling back to the pipeline's first stage
  # when neither a rule nor the form default provides one (CreationService requires a stage).
  def resolve_destination(answers)
    pipeline_id, stage_id = @form.resolve_destination(answers)
    stage_id ||= Pipeline.find_by(id: pipeline_id)&.pipeline_stages&.order(:position)&.first&.id
    [pipeline_id, stage_id]
  end

  # Routes each answer into the bucket its mapping target points to, so the form's
  # configured targets and the lead the API creates stay 1:1 (B14.06).
  def build_lead_params(answers, pipeline_id, stage_id)
    contact = {}
    contact_attributes = {}
    deal_value = nil
    deal_fields = {}

    Array(@form.fields).each do |field|
      value = answers[field['key']]
      next if value.nil?

      bucket, target_key = CrmForm.field_target(field)
      case bucket
      when :contact
        contact[CONTACT_KEYS.fetch(target_key)] = value
      when :contact_attribute
        contact_attributes[target_key] = value
      when :deal_value
        deal_value = value
      when :deal_attribute
        deal_fields[target_key] = value
      else
        # Unmapped fields are still kept on the deal so nothing is silently lost.
        deal_fields[field['key']] = value
      end
    end

    contact[:custom_attributes] = contact_attributes if contact_attributes.any?

    {
      contact: contact,
      deal: { pipeline_id: pipeline_id, stage_id: stage_id, value: deal_value }.compact,
      custom_fields: deal_fields,
      metadata: { form_slug: @form.slug, lead_source: 'crm_form' }
    }
  end

  # Standard contact target keys -> CreationService contact param keys.
  CONTACT_KEYS = { 'name' => :name, 'email' => :email, 'phone' => :phone_number, 'company' => :company }.freeze
end
