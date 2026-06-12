class Conversations::PermissionFilterService
  attr_reader :conversations, :user

  def initialize(conversations, user, _account = nil)
    @conversations = conversations
    @user = user
  end

  def perform
    # Service-token (internal) calls have no Current.user. Treat them as
    # fully trusted/internal and skip inbox-based filtering, since the
    # caller already scopes the query (e.g. by contact_id).
    return conversations if user.nil? || user_role == 'administrator'

    accessible_conversations
  end

  private

  def accessible_conversations
    conversations.where(inbox: user.inboxes)
  end

  def user_role
    user.role
  end
end

Conversations::PermissionFilterService.prepend_mod_with('Conversations::PermissionFilterService')
