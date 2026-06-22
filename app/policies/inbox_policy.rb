class InboxPolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @scope = scope
    end

    def resolve
      user.assigned_inboxes
    end
  end

  def index?
    true
  end

  def show?
    return true if service_authenticated?

    # FIXME: for agent bots, lets bring this validation to policies as well in future
    return true if @user.is_a?(AgentBot)

    # Admins or users granted `conversations.read_all` (resolved into Current by
    # EvoAuthConcern — the CRM `has_permission?` is a no-op stub) can view any inbox.
    return true if @user&.administrator? || Current.evo_can_read_all_inboxes

    # Restricted users can only view their assigned inboxes. `assigned_inboxes`
    # itself returns all inboxes when the user has no inbox_member (opt-in default).
    Current.user&.assigned_inboxes&.include?(record) || false
  end

  def assignable_agents?
    true
  end

  def agent_bot?
    true
  end

  def campaigns?
    @user.administrator?
  end

  def create?
    return true if service_authenticated?
    @user&.administrator? || @user&.has_permission?('inboxes.create')
  end

  def update?
    return true if service_authenticated?
    @user&.administrator? || @user&.has_permission?('inboxes.update')
  end

  def destroy?
    return true if service_authenticated?
    @user&.administrator? || @user&.has_permission?('inboxes.delete')
  end

  def set_agent_bot?
    return true if service_authenticated?
    @user&.administrator? || @user&.has_permission?('inboxes.update')
  end

  def avatar?
    return true if service_authenticated?
    @user&.administrator? || @user&.has_permission?('inboxes.update')
  end

  def setup_channel_provider?
    return true if service_authenticated?
    @user&.administrator? || @user&.has_permission?('inboxes.update')
  end

  def disconnect_channel_provider?
    return true if service_authenticated?
    @user&.administrator? || @user&.has_permission?('inboxes.update')
  end

  def sync_whatsapp_templates?
    @user.administrator? || @user.has_permission?('inboxes.sync_whatsapp_templates')
  end

  def whatsapp_templates?
    @user.administrator? || @user.has_permission?('inboxes.whatsapp_templates')
  end

  def update_whatsapp_template?
    @user.administrator? || @user.has_permission?('inboxes.update_whatsapp_template')
  end

  def delete_whatsapp_template?
    @user.administrator? || @user.has_permission?('inboxes.delete_whatsapp_template')
  end

  # Generic message templates (for all channel types)
  def message_templates?
    # s2s callers (evo-flow journey nodes, EVO-1255) list an inbox's templates
    # with the service token — the same trust level that already allows global
    # template CRUD via ?global=true. Without this, pundit_user carries a nil
    # user and the call 500s.
    return true if service_authenticated?

    @user.administrator? || @user.has_permission?('inboxes.message_templates')
  end

  def update_message_template?
    @user.administrator? || @user.has_permission?('inboxes.update_message_template')
  end

  def delete_message_template?
    @user.administrator? || @user.has_permission?('inboxes.delete_message_template')
  end
end
