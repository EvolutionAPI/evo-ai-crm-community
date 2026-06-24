# EVO-1891: propagate an agent's outgoing message deletion to the WhatsApp
# provider (delete-for-everyone) OUTSIDE the request cycle, so a slow or
# unreachable provider never blocks the CRM soft-delete. Records whether the
# revoke actually propagated so the UI can flag CRM-only deletions.
class Whatsapp::DeleteMessageOnProviderJob < ApplicationJob
  queue_as :low

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message&.outgoing?

    channel = message.conversation&.inbox&.channel
    return unless channel.respond_to?(:delete_message)

    propagated = channel.delete_message(message)
    message.update!(content_attributes: message.content_attributes.merge(revoke_propagated: propagated))
  end
end
