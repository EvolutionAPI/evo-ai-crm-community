# Herda diretamente do controller de accounts
class Api::V1::Oauth::ConversationsController < Api::V1::ConversationsController
  # Remove parent controller middlewares for OAuth
  skip_before_action :authenticate_request!

  skip_before_action :conversation
  skip_before_action :inbox
  skip_before_action :contact
  skip_before_action :contact_inbox

  # Aplica middleware OAuth
  include Doorkeeper::Rails::Helpers
  include OauthAccountHelper
  before_action :ensure_oauth_authentication!
  before_action :conversation, except: [:index, :meta, :search, :create, :filter, :available_for_pipeline]
  before_action :inbox, :contact, :contact_inbox, only: [:create]

  # Override available_for_pipeline to ensure it works with OAuth
  def available_for_pipeline
    # Get all conversations that are open or pending and NOT already in any pipeline.
    # Scope by the caller's accessible inboxes. NOTE: this OAuth path runs its own
    # `ensure_oauth_authentication!` (sets Current.user only) and never reaches
    # EvoAuthConcern#set_current_user_from_auth_data, so Current.evo_role_key and
    # Current.evo_can_read_all_inboxes are nil here — an OAuth admin is therefore
    # scoped as a non-admin. assigned_inboxes still degrades to all-inboxes when the
    # user has no inbox_member (opt-in default). See implementation report divergence.
    scoped = Conversations::PermissionFilterService.new(Conversation.all, current_user).perform
    @available_conversations = scoped
                                      .joins(:contact, :inbox)
                                      .where.missing(:pipeline_items)
                                      .where(status: %w[open pending])
                                      .includes(:contact, :inbox, :assignee, :team)
                                      .order(last_activity_at: :desc)
                                      .limit(50)

    # Apply search filter if provided
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      @available_conversations = @available_conversations.where(
        'conversations.id::text ILIKE ? OR contacts.name ILIKE ? OR contacts.email ILIKE ? OR contacts.phone_number ILIKE ?',
        search_term, search_term, search_term, search_term
      )
    end

    render 'api/v1/conversations/available_for_pipeline'
  end

  private

  def ensure_oauth_authentication!
    unless oauth_token_present?
      render_unauthorized('OAuth token required. This endpoint only accepts OAuth authentication.')
      return
    end

    # Verificar se o token é válido antes de chamar doorkeeper
    token = Doorkeeper::AccessToken.by_token(doorkeeper_token_value)
    unless token&.accessible?
      render_unauthorized('Invalid or expired OAuth token')
      return
    end

    # Verificar se tem escopo adequado
    unless token.acceptable?(['admin']) || token.acceptable?(['read']) || token.acceptable?(['conversations:read'])
      render_unauthorized('Insufficient scope for this endpoint')
      return
    end

    # Token válido, continuar com autenticação
    @resource = User.find(token.resource_owner_id) if token.resource_owner_id
    Current.user = @resource if @resource
  end

  def doorkeeper_token_value
    request.headers['Authorization']&.gsub(/^Bearer\s+/, '')
  end

  # OAuth-aware version of parent controller methods with UUID support
  def conversation
    @conversation ||= resolve_conversation_with_includes(params[:id])
    raise ActiveRecord::RecordNotFound if @conversation.nil?

    authorize @conversation.inbox, :show?
  end

  def inbox
    return if params[:inbox_id].blank?

    @inbox = Inbox.all.find(params[:inbox_id])
    authorize @inbox, :show?
  end

  def contact
    return if params[:contact_id].blank?

    @contact = Contact.all.find(params[:contact_id])
  end

  def contact_inbox
    @contact_inbox = build_contact_inbox

    # fallback for the old case where we do look up only using source id
    # In future we need to change this and make sure we do look up on combination of inbox_id and source_id
    # and deprecate the support of passing only source_id as the param
    # Fallback: look up contact_inbox by source_id
    if @contact_inbox.blank? && params[:source_id].present?
      if @inbox.present?
        # If inbox is already set, use it for validation
        @contact_inbox = ContactInbox.find_by(inbox: @inbox, source_id: params[:source_id])
      else
        @contact_inbox = ::ContactInbox.find_by(source_id: params[:source_id])
      end
      raise ActiveRecord::RecordNotFound if @contact_inbox.nil?
    end
    
    authorize @contact_inbox.inbox, :show? if @contact_inbox.present?
  rescue ActiveRecord::RecordNotUnique
    # If RecordNotUnique occurs, try to find with inbox constraint
    @contact_inbox = ContactInbox.find_by!(inbox: @inbox, source_id: params[:source_id]) if @inbox.present?
    raise ActiveRecord::RecordNotFound if @contact_inbox.nil?
  end
end
