# frozen_string_literal: true

# Public-facing serialization of a CrmForm — only what the anonymous page needs
# to render. Deliberately omits internals (routing_rules, pipeline ids, etc.).
module CrmFormPublicSerializer
  extend self

  def serialize(form)
    {
      slug: form.slug,
      title: form.display_title,
      description: form.description,
      appearance: form.appearance || {},
      fields: public_fields(form.fields)
    }
  end

  private

  def public_fields(fields)
    Array(fields).map do |field|
      {
        key: field['key'],
        label: field['label'],
        type: field['type'].presence || 'text',
        required: field['required'] == true,
        placeholder: field['placeholder'],
        options: field['options']
      }.compact
    end
  end
end
