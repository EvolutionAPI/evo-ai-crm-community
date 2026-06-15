class MessageTemplates::Template::Greeting
  include MessageTemplates::Template::TemplateContent

  pattr_initialize [:conversation!]

  def perform
    content = greeting_content
    # Skip silently when neither the template nor the inline fallback yields
    # content, so a blank auto-reply is never delivered (EVO-1720 [6.11]).
    return if content.blank?

    ActiveRecord::Base.transaction do
      conversation.messages.create!(
        inbox_id: @conversation.inbox_id,
        message_type: :template,
        content: content
      )
    end
  rescue StandardError => e
    EvolutionExceptionTracker.new(e, account: nil).capture_exception
    true
  end

  private

  delegate :contact, to: :conversation
  delegate :inbox, to: :message

  # Prefer a referenced MessageTemplate (EVO-1235); fall back to the inline
  # string. Resolved once so the blank guard adds no extra SendResolver lookup.
  def greeting_content
    template_content_for(@conversation.inbox&.greeting_message_template_id) ||
      @conversation.inbox&.greeting_message
  end
end
