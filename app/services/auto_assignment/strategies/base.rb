# frozen_string_literal: true

module AutoAssignment
  module Strategies
    module Base
      # Interface contract for all routing strategies.
      #
      # Every strategy MUST implement:
      #   .call(conversation, allowed_agent_ids: [String]) -> User | nil
      #
      # Preconditions:
      #   - conversation:       Conversation AR instance
      #   - allowed_agent_ids:  Array of agent IDs (Strings, as returned by
      #                         OnlineStatusTracker via Redis); may be empty
      #
      # Postconditions:
      #   - Returns a User instance when an agent is found
      #   - Returns nil when no agent is available (caller handles nil)
      #   - NEVER raises an exception due to absence of agents
      #   - Use User.find_by(user_id:) / inbox_member lookup — never User.find()
    end
  end
end
