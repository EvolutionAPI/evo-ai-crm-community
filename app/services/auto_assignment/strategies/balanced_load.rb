# frozen_string_literal: true

module AutoAssignment
  module Strategies
    class BalancedLoad
      include AutoAssignment::Strategies::Base

      # @param conversation      [Conversation]
      # @param allowed_agent_ids [Array<Integer, String>] — normalized internally (Redis returns Strings)
      # @return [User, nil]
      def self.call(conversation, allowed_agent_ids:)
        return nil if allowed_agent_ids.empty?

        string_ids = allowed_agent_ids.map(&:to_s)

        counts = Conversation
                 .where(assignee_id: string_ids, status: :open)
                 .group(:assignee_id)
                 .count

        min_id = string_ids.min_by { |id| counts.fetch(id, 0) }

        User.find_by(id: min_id)
      end
    end
  end
end
