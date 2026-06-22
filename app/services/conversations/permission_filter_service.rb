class Conversations::PermissionFilterService
  attr_reader :conversations, :user

  def initialize(conversations, user, _account = nil)
    @conversations = conversations
    @user = user
  end

  def perform
    # No resolvable user (e.g. service-token contexts) degrades to all conversations,
    # preserving the pre-feature behavior and avoiding a NoMethodError on user.role.
    return conversations if user.nil? || user_role == 'administrator'

    accessible_conversations
  end

  private

  def accessible_conversations
    # Use assigned_inboxes (not raw inboxes) so the opt-in default (no assignment =
    # see all) and `conversations.read_all` are honored consistently. Degrade to
    # all inboxes when there is no resolvable user (e.g. service contexts).
    accessible = user&.assigned_inboxes || Inbox.all
    conversations.where(inbox: accessible)
  end

  def user_role
    user.role
  end
end

Conversations::PermissionFilterService.prepend_mod_with('Conversations::PermissionFilterService')
