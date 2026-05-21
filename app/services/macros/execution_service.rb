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

    @pending_webhook_jobs = []
    run_actions
    finalize_execution
    enqueue_pending_webhooks
    @execution
  rescue StandardError => e
    if @execution
      @execution.fail!(error: e.message, actions_result: @actions_result)
      dispatch_completion
    end
    raise
  ensure
    Current.reset
  end

  private

  def run_actions
    @has_failure = false
    @has_async = false

    @macro.actions.each do |action|
      action = action.with_indifferent_access
      execute_action(action[:action_name], action[:action_params])
    end
  end

  def execute_action(action_name, params)
    result = send(action_name, params)
    if action_name == 'send_webhook_event' && result.is_a?(Hash) && result[:status] == :pending_enqueue
      @has_async = true
      @actions_result << { action: action_name, status: 'enqueued' }
      @pending_webhook_jobs << result
    else
      @actions_result << { action: action_name, status: 'success' }
    end
  rescue StandardError => e
    @has_failure = true
    @actions_result << { action: action_name, status: 'failed', error: e.message }
    EvolutionExceptionTracker.new(e).capture_exception
  end

  def finalize_execution
    # Persist actions_result BEFORE enqueuing webhook jobs to prevent a race
    # where Sidekiq finalizes before the main thread writes the 'enqueued'
    # marker, causing the WebhookJob's update to be overwritten.
    if @has_failure
      @execution.fail!(error: 'One or more actions failed', actions_result: @actions_result)
      dispatch_completion
    elsif @has_async
      # Webhook is still in-flight; WebhookJob marks status and dispatches the
      # completion event when it finishes.
      @execution.update!(actions_result: @actions_result)
    else
      @execution.complete!(actions_result: @actions_result)
      dispatch_completion
    end
  end

  def enqueue_pending_webhooks
    # Do not enqueue async work if the sync portion already failed — the
    # execution is already :failed and the webhook attempt would noise up
    # the state machine.
    return if @has_failure

    @pending_webhook_jobs.each do |job|
      WebhookJob.perform_later(job[:url], job[:payload], :macro_webhook, @execution.id)
    end
  end

  def dispatch_completion
    Rails.configuration.dispatcher.dispatch(
      Events::Types::MACRO_EXECUTION_COMPLETED,
      Time.zone.now,
      macro_execution: @execution
    )
  end

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
      EvolutionExceptionTracker.new(e).capture_exception
      { event: 'macro.executed', conversation_id: @conversation.id, macro_id: @macro.id }
    end

    # Return job descriptor so `#perform` can enqueue AFTER persisting the
    # 'enqueued' marker in actions_result. Sidekiq retry + Sentry visibility
    # from EVO-1041 are preserved by WebhookJob, which updates MacroExecution
    # to :failed on definitive failure (after retries exhausted).
    { status: :pending_enqueue, url: clean_url, payload: payload }
  end
end
