class WebhookJob < ApplicationJob
  queue_as :medium
  # Webhook types: :account_webhook (default), :inbox_webhook, :agent_bot,
  # :api_inbox_webhook, :macro_webhook. Only :macro_webhook re-raises on
  # failure so Sidekiq surfaces the error; others swallow-and-warn per the
  # legacy contract (see lib/webhooks/trigger.rb#execute).
  def perform(url, payload, webhook_type = :account_webhook, macro_execution_id = nil)
    Webhooks::Trigger.execute(url, payload, webhook_type)
    finalize_macro_execution_success(macro_execution_id) if macro_execution_id
  rescue StandardError => e
    finalize_macro_execution_failure(macro_execution_id, e) if macro_execution_id
    raise
  end

  private

  def finalize_macro_execution_success(macro_execution_id)
    execution = MacroExecution.find_by(id: macro_execution_id)
    return unless execution

    finalized = false
    execution.with_lock do
      execution.reload
      next unless execution.pending?

      actions_result = mark_webhook_action(execution.actions_result || [], status: 'success')
      execution.complete!(actions_result: actions_result)
      finalized = true
    end
    dispatch_completion(execution) if finalized
  end

  def finalize_macro_execution_failure(macro_execution_id, error)
    execution = MacroExecution.find_by(id: macro_execution_id)
    return unless execution

    execution.with_lock do
      execution.reload
      actions_result = mark_webhook_action(
        execution.actions_result || [],
        status: 'failed',
        error: error.message
      )
      execution.fail!(
        error: "Webhook delivery failed: #{error.message}",
        actions_result: actions_result
      )
    end
    dispatch_completion(execution)
  end

  def mark_webhook_action(actions_result, status:, error: nil)
    found = false
    updated = actions_result.map do |entry|
      entry = entry.with_indifferent_access if entry.respond_to?(:with_indifferent_access)
      next entry unless entry[:action].to_s == 'send_webhook_event' && entry[:status].to_s == 'enqueued'

      found = true
      entry.merge('status' => status).tap { |h| h['error'] = error if error }
    end
    return updated if found

    updated + [{ 'action' => 'send_webhook_event', 'status' => status, 'error' => error }.compact]
  end

  def dispatch_completion(execution)
    Rails.configuration.dispatcher.dispatch(
      Events::Types::MACRO_EXECUTION_COMPLETED,
      Time.zone.now,
      macro_execution: execution
    )
  end
end
