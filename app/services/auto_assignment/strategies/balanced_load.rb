# frozen_string_literal: true

module AutoAssignment
  module Strategies
    class BalancedLoad
      include AutoAssignment::Strategies::Base

      # @param _conversation     [Conversation] required by Strategies::Base contract; unused by BalancedLoad
      # @param allowed_agent_ids [Array<String>] UUID strings (as stored and returned by Redis/OnlineStatusTracker)
      # @return [User, nil]
      def self.call(_conversation, allowed_agent_ids:)
        ids = Array(allowed_agent_ids)
        return nil if ids.empty?

        string_ids = ids.map(&:to_s)

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
