# frozen_string_literal: true

# Raised by Conversation#return_to_bot! when preconditions for the reverse
# human→bot handoff are not met (no AgentBot connected to the inbox, or the
# conversation is not currently open). Caught by the controller and translated
# to a 422 Unprocessable Entity response (EVO-1680).
module Conversations
  class InvalidHandoffError < StandardError; end
end
