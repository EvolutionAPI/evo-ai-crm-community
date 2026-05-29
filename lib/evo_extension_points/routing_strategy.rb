# frozen_string_literal: true

module EvoExtensionPoints
  # Routing strategy extension point. Community default: nil (no-op).
  # AgentAssignmentService falls back to AutoAssignment::Strategies::RoundRobin
  # when no override is registered.
  #
  # Override via:
  #   EvoExtensionPoints.replace(:routing_strategy) do |conversation, allowed_agent_ids:|
  #     MyCustomStrategy.call(conversation, allowed_agent_ids: allowed_agent_ids)
  #   end
  #
  # Interface contract: .call(conversation, allowed_agent_ids: [String]) → User | nil
  # Ruby contract module: AutoAssignment::Strategies::Base (include in strategy classes)
  # See EXTENSION_POINTS.md for the full contract and versioning policy.
  module RoutingStrategy
    # No-op: nil → AgentAssignmentService uses Strategies::RoundRobin as fallback
  end
end
