# Automation Rules — Action Handlers

This directory hosts two executor surfaces that share their action implementations through a small set of mixins. Adding a new node type means touching three or four files following the pattern below.

## Two executors, not one

| File | Runs when | Iterates |
|---|---|---|
| `action_service.rb` (`AutomationRules::ActionService`) | `AutomationRule.mode == 'simple'` — the modal-style rule | `@rule.actions` (a JSON array of `{action_name, action_params}` entries) |
| `flow_execution_service.rb` (`AutomationRules::FlowExecutionService`) | `AutomationRule.mode == 'flow'` — the mini-canvas embedded in an automation rule | `@rule.flow_data.nodes` connected by `@rule.flow_data.edges` |

> **What this directory is NOT.** The Customer Journey / "Flow Builder" canvas at `/journey/<id>/flow` is a separate product. Its executor lives in the `evo-flow` service (`evo-flow/src/modules/temporal/`) and runs via Temporal workflows. CRM-side action services here are invoked only by AutomationRule listeners (`app/listeners/automation_rule_listener.rb`).

## Shared modules

Both executors call the same Ruby methods for the cross-cutting actions:

- `pipeline_action_handlers.rb` (`AutomationRules::PipelineActionHandlers`) — `assign_to_pipeline`, `update_pipeline_stage`, `create_pipeline_task`, helpers.
- `message_action_handlers.rb` (`AutomationRules::MessageActionHandlers`) — `send_canned_response`, `send_template` (with `{{contact.field}}` / `{{conversation.field}}` resolution), helpers.

Each module declares its methods `private`; when included into a class, they become private instance methods of that class. Both `ActionService` and `FlowExecutionService` include the modules; behaviour is identical between the two surfaces because the implementation is identical.

## How to add a new node type

Use the assign-to-pipeline node delivered in EVO-1262 as a worked example.

### 1. Decide whether the action is shared

If a node maps 1:1 to an existing `ActionService` action that is already callable from the modal rule, extract it into a shared module (or extend an existing one) so the canvas executor can call the same code path. If the action is canvas-only (e.g. branching control flow), keep it inside `FlowExecutionService`.

### 2. (If shared) Move the action body into the relevant module

Modules live under `app/services/automation_rules/<domain>_action_handlers.rb`. Conventions:

- Module body starts with `private` so all methods become private when included.
- Methods read `@rule` and `@conversation` (and `@contact` if your action needs it) — both executors have these instance variables.
- Helpers (logging, parameter extraction, …) stay in the same module beside the main method.
- Top-level rubocop directives that the original method carried (`Metrics/AbcSize` etc.) move with the method.

Add a docstring at the top of the module listing:

- Which executors include it.
- Which instance variables it relies on.
- Which other predicates it needs (e.g. `conversation_a_tweet?`).

### 3. Include the module in both executors

```ruby
class AutomationRules::ActionService < ActionService
  include AutomationRules::<Domain>ActionHandlers
  # …
end

class AutomationRules::FlowExecutionService
  include AutomationRules::<Domain>ActionHandlers
  # …
end
```

Run `bundle exec rspec spec/services/automation_rules/action_service_spec.rb` after the include — it must pass unchanged. If it doesn't, you altered behaviour during extraction.

### 4. Wire the canvas dispatch

In `flow_execution_service.rb`:

- Add the new node-type string to the whitelist in `action_node?` (e.g. `'assign-to-pipeline-node'`). Kebab-case + `-node` suffix is the convention.
- Add a `when` branch in `execute_node_action`'s `case node_type` that normalises `node_data` to the array-of-hash shape ActionService expects, then invokes the private method.

```ruby
when 'assign-to-pipeline-node'
  pipeline_id = node_data['pipeline_id'] || node_data['id']
  assign_to_pipeline([{ id: pipeline_id }]) if pipeline_id
```

The normalisation step matters because `node_data` comes from the canvas component (where keys are usually descriptive, e.g. `pipeline_id`) while `action_params` from the modal rule carries the legacy `{id: …}` shape. Pass through both for forward compatibility.

### 5. Spec the new node type

Add at least:

- A happy-path spec under `spec/services/automation_rules/flow_execution_service_spec.rb` driving `execute_node_action` directly with a hand-built `node` hash. Assert the observable side effect (DB row created, Sidekiq job enqueued, Wisper event broadcast).
- A no-op spec for the missing-required-field path (e.g. node_data without the ID).
- A parity assertion under the existing `'EVO-1262 parity'` describe block: drive the same logical action through `ActionService.perform` (with `@rule.actions` configured) and through `FlowExecutionService.execute_node_action` (with a flow node), then compare DB state.

If your action depends on a model/feature with peculiar test setup (e.g. `create_pipeline_task` needs a `SuperAdmin` user that the Community fork no longer ships), seed it explicitly or stub the lookup — production code's silent-rescue path swallows the failure and the test would pass-then-fail-in-prod otherwise.

### 6. (Frontend, out of this directory) Build the node config component

This is owned by the downstream node card (10.13-10.19). The React side lives in `evo-ai-frontend-community/src/components/journey/nodes/`. It emits `node_data` whose keys match what step 4 reads.

## Spec coverage matrix

| Area | Spec file |
|---|---|
| ActionService modal-rule iteration + per-action dispatch | `spec/services/automation_rules/action_service_spec.rb` |
| FlowExecutionService canvas-execution + per-node-type dispatch | `spec/services/automation_rules/flow_execution_service_spec.rb` |
| Cross-surface parity (modal vs canvas produce same DB state) | The `'EVO-1262 parity'` describe block in the same file |
| Module behaviour | Indirectly via both files — no standalone module specs by design (the two executor specs together fully cover the modules' surface) |

## Antipatterns

- ❌ Calling `ActionService.new(...).send(:private_method)` from `FlowExecutionService` — fragile to refactors, doesn't share `@conversation`'s identity. Use the include path instead.
- ❌ Duplicating action logic between `action_service.rb` and `flow_execution_service.rb` — silent divergence is the failure mode the modules exist to prevent.
- ❌ Marking module methods `public` — the methods are dispatched via internal `send` or direct invocation; exposing them publicly invites external callers and complicates the API surface.
- ❌ Adding canvas-side action logic to `evo-flow` Temporal workflows that duplicates this directory — keep CRM action logic CRM-side; the canvas calls back via HTTP (out of scope here, owned by the consuming node cards).
