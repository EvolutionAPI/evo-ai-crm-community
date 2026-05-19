class WebhookJob < ApplicationJob
  queue_as :medium
  # Webhook types: :account_webhook (default), :inbox_webhook, :agent_bot,
  # :api_inbox_webhook, :macro_webhook. Only :macro_webhook re-raises on
  # failure so Sidekiq surfaces the error; others swallow-and-warn per the
  # legacy contract (see lib/webhooks/trigger.rb#execute).
  def perform(url, payload, webhook_type = :account_webhook, macro_execution_id = nil)
    Webhooks::Trigger.execute(url, payload, webhook_type)
  rescue StandardError => e
    if macro_execution_id && (execution = MacroExecution.find_by(id: macro_execution_id))
      execution.fail!(
        error: "Webhook delivery failed: #{e.message}",
        actions_result: (execution.actions_result || []) + [{ action: 'send_webhook_event', status: 'failed', error: e.message }]
      )
    end
    raise
  end
end
