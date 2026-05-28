module EvoFlow
  # Distinct Wisper channels from PublishEventWorker so alerts can route
  # "backfill stuck" separately from "live integration degraded".
  class BackfillFailureBroadcaster
    include Wisper::Publisher

    def broadcast_failed(account_id:, error:)
      publish(
        'evo_flow_backfill_failed',
        data: { account_id: account_id, error: error }
      )
    end

    def broadcast_dropped(reason:, account_id:, source:, error_message:)
      publish(
        'evo_flow_backfill_dropped',
        data: {
          reason: reason, account_id: account_id, source: source,
          error_message: error_message
        }
      )
    end
  end
end
