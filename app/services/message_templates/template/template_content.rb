# frozen_string_literal: true

# Shared helper for the greeting / out-of-office auto-reply templates: resolves
# the inbox's optional MessageTemplate reference (EVO-1235 [6.6]) and renders it
# with the conversation contact's variables, falling back to nil (so the caller
# uses the legacy inline string column) when there is no template, it cannot be
# resolved, or a required variable is missing.
#
# Expects the including class to expose `@conversation`.
module MessageTemplates::Template::TemplateContent
  private

  def template_content_for(template_id)
    return nil if template_id.blank?

    template = MessageTemplates::SendResolver.new(
      id: template_id,
      channel: @conversation.inbox&.channel
    ).resolve
    return nil if template.nil?

    template.render_with_variables(contact_template_variables)
  rescue ArgumentError => e
    Rails.logger.warn "[templates] auto-reply template #{template_id} render failed: #{e.message}; falling back to inline content"
    nil
  end

  def contact_template_variables
    contact = @conversation.contact
    return {} if contact.nil?

    {
      'first_name' => contact.name.to_s.split.first,
      'name' => contact.name,
      'email' => contact.email
    }.compact
  end
end
