# frozen_string_literal: true

module AutoAssignment
  module Strategies
    class FallbackChain
      # Note: FallbackChain extends the base interface with a required `chain:` keyword arg.
      # It is not a drop-in replacement by itself; use it inside a replace(:routing_strategy) block:
      #
      #   EvoExtensionPoints.replace(:routing_strategy) do |conversation, allowed_agent_ids:|
      #     FallbackChain.call(conversation,
      #                        allowed_agent_ids: allowed_agent_ids,
      #                        chain: [BalancedLoad, RoundRobin])
      #   end
      #
      # @param conversation      [Conversation]
      # @param allowed_agent_ids [Array<Integer, String>]
      # @param chain             [Array<Class>] strategies to try in order
      # @return [User, nil]
      def self.call(conversation, allowed_agent_ids:, chain:)
        chain.each do |strategy|
          begin
            result = strategy.call(conversation, allowed_agent_ids: allowed_agent_ids)
            return result unless result.nil?
          rescue => e
            Rails.logger.error("[FallbackChain] strategy #{strategy} raised: #{e.message}")
          end
        end
        nil
      end
    end
  end
end
