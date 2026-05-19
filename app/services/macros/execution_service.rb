# frozen_string_literal: true

class Macros::ExecutionService < ActionService
  def initialize(macro, conversation, user)
    super(conversation)
    @macro = macro
    @user = user
    @actions_result = []
    Current.user = user
  end

  def perform
    @execution = MacroExecution.create!(
      macro: @macro,
      conversation: @conversation,
      user: @user,
      status: :pending
    )

    has_failure = false

    @macro.actions.each do |action|
      action = action.with_indifferent_access
      begin
        send(action[:action_name], action[:action_params])
        @actions_result << { action: action[:action_name], status: 'success' }
      rescue StandardError => e
        has_failure = true
        @actions_result << { action: action[:action_name], status: 'failed', error: e.message }
        EvolutionExceptionTracker.new(e).capture_exception
      end
    end

    if has_failure
      @execution.fail!(error: 'One or more actions failed', actions_result: @actions_result)
    else
      @execution.complete!(actions_result: @actions_result)
    end

    @execution
  rescue StandardError => e
    @execution&.fail!(error: e.message, actions_result: @actions_result)
    raise
  ensure
    Current.reset
  end

  private

  def assign_agent(agent_ids)
    agent_ids = agent_ids.map { |id| id == 'self' ? @user.id : id }
    super(agent_ids)
  end

  def add_private_note(message)
    return if conversation_a_tweet?

    params = { content: message[0], private: true }

    # Added reload here to ensure conversation us persistent with the latest updates
    mb = Messages::MessageBuilder.new(@user, @conversation.reload, params)
    mb.perform
  end

  def send_message(message)
    return if conversation_a_tweet?

    params = { content: message[0], private: false }

    # Added reload here to ensure conversation us persistent with the latest updates
    mb = Messages::MessageBuilder.new(@user, @conversation.reload, params)
    mb.perform
  end

  def send_attachment(attachment_params)
    return if conversation_a_tweet?

    # Suporte para formato antigo (array de IDs) e novo formato (hash com opções)
    if attachment_params.is_a?(Array)
      # Formato legado: apenas array de blob_ids
      blob_ids = attachment_params
      inbox_id = nil
    elsif attachment_params.is_a?(Hash)
      # Novo formato: hash com attachment_ids e inbox_id opcional
      blob_ids = attachment_params[:attachment_ids] || attachment_params['attachment_ids']
      inbox_id = attachment_params[:inbox_id] || attachment_params['inbox_id']
    else
      # Formato único: assumir que é um array de IDs
      blob_ids = [attachment_params].flatten
      inbox_id = nil
    end

    return unless @macro.files.attached?

    blobs = ActiveStorage::Blob.where(id: blob_ids)

    return if blobs.blank?

    # Preparar parâmetros da mensagem
    params = { content: nil, private: false, attachments: blobs }
    
    # Se um inbox específico foi fornecido, validar se a conversa pertence a esse inbox
    if inbox_id
      inbox = Inbox.find_by(id: inbox_id)
      if inbox && @conversation.inbox != inbox
        Rails.logger.warn "Macro #{@macro.id}: Inbox mismatch. Conversation inbox: #{@conversation.inbox.id}, Requested inbox: #{inbox_id}"
        # Por ora, vamos logar e continuar com o inbox da conversa
      end
    end

    # Added reload here to ensure conversation us persistent with the latest updates
    mb = Messages::MessageBuilder.new(@user, @conversation.reload, params)
    mb.perform
  rescue StandardError => e
    Rails.logger.error "Macro #{@macro.id}: Error sending attachment: #{e.message}"
    raise e
  end

  # `webhook_url` comes from the macro JSON `action_params`. Historically the
  # field is stored as `[url_string]`, but defensive handling for nil / bare
  # string is kept so a malformed macro entry does not crash the whole
  # execution loop.
  def send_webhook_event(webhook_url)
    clean_url = Array(webhook_url).first.to_s.strip
    if clean_url.blank?
      Rails.logger.warn "Macro #{@macro.id}: skipping send_webhook_event — empty URL"
      return
    end

    payload = begin
      @conversation.webhook_data.merge(event: 'macro.executed')
    rescue StandardError => e
      Rails.logger.warn "Macro #{@macro.id}: failed to build webhook payload: #{e.message}"
      { event: 'macro.executed', conversation_id: @conversation.id, macro_id: @macro.id }
    end

    # Execute synchronously with timeout so failures are captured in MacroExecution
    Rails.logger.info "Macro #{@macro.id}: executing webhook synchronously for status tracking"
    Timeout.timeout(10) do
      Webhooks::Trigger.execute(clean_url, payload, :macro_webhook)
    end
  end
end
