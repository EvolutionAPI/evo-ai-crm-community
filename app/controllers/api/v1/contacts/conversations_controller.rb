class Api::V1::Contacts::ConversationsController < Api::V1::Contacts::BaseController
  def index
    # Start with all conversations for this contact
    conversations = Conversation.includes(
      :assignee, :contact, :inbox, :taggings, { pipeline_items: [:pipeline, :pipeline_stage] }
    ).where(contact_id: @contact.id)

    # Apply permission-based filtering using the existing service
    conversations = Conversations::PermissionFilterService.new(
      conversations,
      Current.user,
      nil
    ).perform

    @conversations = conversations.order(last_activity_at: :desc).limit(20)

    success_response(data: ConversationSerializer.serialize_collection(@conversations, include_labels: true))
  end
end
