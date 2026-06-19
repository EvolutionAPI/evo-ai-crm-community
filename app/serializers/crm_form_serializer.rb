# frozen_string_literal: true

# CrmFormSerializer - full (admin) serialization of a CrmForm.
#
# Plain Ruby module matching the convention used by ProductSerializer /
# AutomationRuleSerializer in this app.
module CrmFormSerializer
  extend self

  def serialize(form, leads_count: nil)
    data = {
      id: form.id,
      name: form.name,
      slug: form.slug,
      title: form.title,
      description: form.description,
      appearance: form.appearance || {},
      fields: form.fields || [],
      routing_rules: form.routing_rules || [],
      default_pipeline_id: form.default_pipeline_id,
      default_stage_id: form.default_stage_id,
      published: form.published,
      public_path: "/f/#{form.slug}",
      created_at: form.created_at&.iso8601,
      updated_at: form.updated_at&.iso8601
    }
    data[:leads_count] = leads_count unless leads_count.nil?
    data
  end

  def serialize_collection(forms)
    return [] unless forms

    forms.map { |form| serialize(form) }
  end
end
