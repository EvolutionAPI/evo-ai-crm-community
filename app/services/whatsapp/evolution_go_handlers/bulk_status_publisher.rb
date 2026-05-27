# Wisper publisher used by the bulk-receipt path, which preserves
# `update_all` for performance and therefore inlines the broadcast instead
# of using Messages::StatusUpdateService (which performs a per-row update!).
# Payload contract mirrors Messages::StatusUpdateService#perform.
class Whatsapp::EvolutionGoHandlers::BulkStatusPublisher
  include Wisper::Publisher

  def emit(message, previous_status, status, external_error = nil)
    publish(:message_status_changed, data: {
              message: message,
              previous_status: previous_status,
              status: status,
              external_error: external_error
            })
  end
end
