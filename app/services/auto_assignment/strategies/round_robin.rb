# frozen_string_literal: true

module AutoAssignment
  module Strategies
    class RoundRobin
      # @param conversation      [Conversation]
      # @param allowed_agent_ids [Array<String>] string IDs from Redis/OnlineStatusTracker
      # @return [User, nil]
      def self.call(conversation, allowed_agent_ids:)
        return nil if allowed_agent_ids.blank?

        AutoAssignment::InboxRoundRobinService
          .new(inbox: conversation.inbox)
          .available_agent(allowed_agent_ids: allowed_agent_ids)
      end
    end
  end
end
