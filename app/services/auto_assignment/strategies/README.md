# Auto-Assignment Strategies

This directory contains the pluggable routing strategies for `AgentAssignmentService`.

The active strategy is resolved at runtime via `EvoExtensionPoints.replace(:routing_strategy)`.
Without an override the service falls back to `Strategies::RoundRobin` — behaviour identical
to the pre-extension-point code.

See [`EXTENSION_POINTS.md`](../../../../EXTENSION_POINTS.md) for the full consumer contract
and how to register an override from a `Railtie` / `Engine` initializer.

---

## Interface contract

Every strategy MUST implement a single class method:

```ruby
.call(conversation, allowed_agent_ids: [String]) → User | nil
```

| Argument | Type | Notes |
|---|---|---|
| `conversation` | `Conversation` | Active Record instance of the conversation being assigned |
| `allowed_agent_ids` | `Array<String>` | Online agent IDs intersected with inbox members. **Strings** — as returned by `OnlineStatusTracker` via Redis. May be empty. |

Return value: a `User` instance when an agent is selected, or `nil` when none is available.
The caller (`AgentAssignmentService#perform`) handles `nil` by skipping the update.

**The implementation MUST NOT raise an exception due to absence of agents.**
Use `User.find_by(id:)` — never `User.find(id)` — to avoid `ActiveRecord::RecordNotFound`
on stale IDs.

```ruby
module AutoAssignment
  module Strategies
    class MyStrategy
      include AutoAssignment::Strategies::Base

      def self.call(conversation, allowed_agent_ids:)
        ids = Array(allowed_agent_ids)
        return nil if ids.empty?

        # ... select an agent from ids ...

        User.find_by(id: selected_id)
      end
    end
  end
end
```

---

## Shipped strategies

### `Strategies::RoundRobin` (default)

Delegates to `InboxRoundRobinService`, preserving the Redis-backed round-robin
cursor. This is the community default — activated automatically when no override
is registered.

### `Strategies::BalancedLoad`

Selects the online agent with the **fewest open conversations**.
Uses a single `GROUP BY` SQL query — no N+1. UUID-safe (`allowed_agent_ids`
are strings; the query normalises them via `.to_s`).

```ruby
# config/initializers/custom_routing.rb

EvoExtensionPoints.replace(:routing_strategy) do |conversation, allowed_agent_ids:|
  AutoAssignment::Strategies::BalancedLoad.call(
    conversation,
    allowed_agent_ids: allowed_agent_ids
  )
end
```

---

## Example: custom workload scoring strategy

The following is a **reference implementation** showing how to combine two
workload signals — current open conversations and time dedicated to conversations
today — into a single score. It is intentionally not shipped as a community default
because the relative weights of the two signals are a deployment-specific decision.

Copy it into your consumer codebase and adjust the constants to match your context:

```ruby
# frozen_string_literal: true

module MyConsumer
  module Strategies
    class WorkloadScore
      # Weight of the current open-conversation load signal (0.0 – 1.0).
      # The complement (1 - W_LOAD) is applied to the time-dedicated signal.
      W_LOAD = 0.5

      # @param conversation      [Conversation]
      # @param allowed_agent_ids [Array<String>] String IDs from OnlineStatusTracker
      # @return [User, nil]
      def self.call(conversation, allowed_agent_ids:)
        ids = Array(allowed_agent_ids).map(&:to_s)
        return nil if ids.empty?

        # Signal 1: current open-conversation load (lower = better availability)
        open_counts = Conversation
                      .where(assignee_id: ids, status: :open)
                      .group(:assignee_id)
                      .count

        # Signal 2: minutes in conversations resolved today (lower = less busy today)
        # ReportingEvent stores conversation_resolved with value = seconds of duration
        today_seconds = ReportingEvent
                        .where(
                          user_id: ids,
                          name: 'conversation_resolved',
                          created_at: Time.current.all_day
                        )
                        .group(:user_id)
                        .sum(:value)

        # Score: higher is better. 1/(x+1) decays quickly;
        # substitute Math.log(x+2) or Math.sqrt(x+1) for softer decay.
        best_id = ids.max_by do |id|
          load_score  = 1.0 / (open_counts.fetch(id, 0) + 1)
          today_score = 1.0 / ((today_seconds.fetch(id, 0) / 60.0) + 1)
          W_LOAD * load_score + (1 - W_LOAD) * today_score
        end

        User.find_by(id: best_id)
      end
    end
  end
end
```

Activate from your initializer:

```ruby
# config/initializers/custom_routing.rb

EvoExtensionPoints.replace(:routing_strategy) do |conversation, allowed_agent_ids:|
  MyConsumer::Strategies::WorkloadScore.call(
    conversation,
    allowed_agent_ids: allowed_agent_ids
  )
end
```

**Notes on the scoring formula:**

- `W_LOAD = 0.5` weights both signals equally. `0.8` makes open conversation count
  the dominant factor; `0.2` makes accumulated daily time dominant.
- `1/(x+1)` decays fast (10 min → 0.09, 45 min → 0.02). For a softer curve use
  `1 / Math.log(x + 2)` (logarithmic) or `1 / Math.sqrt(x + 1)` (square-root).
- `ReportingEvent` records `conversation_resolved` with `value` = seconds of
  conversation duration, `user_id` = assignee at resolution time. No migration needed.

---

## Testing your strategy

Minimum test surface:

```ruby
RSpec.describe MyConsumer::Strategies::WorkloadScore do
  describe '.call' do
    it 'returns nil when allowed_agent_ids is empty'
    it 'selects the agent with the lowest combined score'
    it 'does not raise when User.find_by returns nil'
  end
end
```
