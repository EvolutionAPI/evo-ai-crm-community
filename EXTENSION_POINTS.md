# Extension Points

**Contract version:** `2.0.0` (SemVer)

This document is the public contract between `evo-ai-crm-community` and
any external consumer that wants to plug into it without forking or
patching community source. The authoritative architectural decision
behind this contract is **ADR13 — Extension Points Versioning Strategy**;
the rules below are self-contained.

The community release is fully usable on its own. Every extension point
ships with a working no-op default; a consumer can **replace** the
default implementation of one or more of them without modifying files
in `app/` or `lib/`.

If you are about to change any of the five extension points below,
read the [Compatibility Promise](#compatibility-promise) first.

---

## Compatibility Promise

Each extension point is versioned independently and treated as a public
API, with the same backward-compatibility rules as the REST `/v1/*`
endpoints:

- **Backward compatibility is forever.** Once shipped at a given major,
  the name, arguments, return shape and observable behavior of an
  extension point do not change silently.
- **Breaking changes require a major bump** of the affected extension
  point and of the community release that ships them.
- **Deprecation window is at least one minor release.** The old shape
  keeps working alongside the new one, and the deprecated path emits a
  warning via `Rails.logger`.
- **Additive changes are minor bumps.** New extension point, or new
  optional capability on an existing one.
- **Bug fixes that preserve the contract are patch bumps.**

Bumping one extension point does not bump the others.

---

## Extension points

All six are exposed under the `EvoExtensionPoints` namespace,
implemented by `lib/evo_extension_points/`. The aggregate contract
version is exposed at `EvoExtensionPoints::EXTENSION_POINTS_VERSION`.

### 1. `capability_gate`

**Version:** `2.0.0`
**Default:** always returns `true`.

```ruby
EvoExtensionPoints::CapabilityGate.enabled?(name, **context) # => Boolean
```

Override:

```ruby
EvoExtensionPoints.replace(:capability_gate) do |name, **context|
  MyConsumer.capability_enabled?(name, **context)
end
```

**Breaking-change policy:** renaming `enabled?`, adding a required
positional argument, or changing the return type from boolean is a major
bump. Adding a new key to `context` or a new accepted `name` is a minor
bump.

### 2. `runtime_context`

**Version:** `2.0.0`
**Default:** `current_scope_id` returns `nil`; `with_scope` yields
without binding any state (single-scope mode).

```ruby
EvoExtensionPoints::RuntimeContext.current_scope_id    # => String | nil
EvoExtensionPoints::RuntimeContext.with_scope(id) { ... } # => yields with scope bound
```

Override:

```ruby
EvoExtensionPoints.replace(:runtime_context_current_id) { MyConsumer::Current.scope_id }
EvoExtensionPoints.replace(:runtime_context_with_scope) do |id, &block|
  MyConsumer::Current.set(scope_id: id, &block)
end
```

**Breaking-change policy:** renaming `current_scope_id` / `with_scope`,
or changing the return type of `current_scope_id` from `String | nil`,
is a major bump. Adding sibling helpers is a minor bump.

### 3. `plugin_loader`

**Version:** `2.0.0`
**Default:** stores registrations in memory and invokes `on_boot`
callbacks at the end of Rails boot. The community release registers
nothing on its own; `plugins` is `[]` until a consumer is installed.

A future evolution toward remote / runtime loading MUST require a
signature or allowlist check at the registry level; the in-memory
default is not a vehicle for arbitrary remote code execution.

```ruby
EvoExtensionPoints::PluginLoader.register_plugin(name) do |plugin|
  plugin.on_boot { ... }
  plugin.routes { |mapper| mapper.mount(...) }
end
EvoExtensionPoints::PluginLoader.plugins # => Array<Symbol>
```

Override (called from a consumer's `Railtie` / `Engine` initializer):

```ruby
EvoExtensionPoints::PluginLoader.register_plugin(:my_consumer) do |plugin|
  plugin.on_boot { Rails.logger.info("[my_consumer] booted") }
  plugin.routes  { |mapper| mapper.mount MyConsumer::Engine => "/my_consumer" }
end
```

**Host-side consumption.** The host invokes the registered callbacks at
two points in the boot sequence:

- `on_boot` — driven by `PluginLoader.load_all`, called from
  `config/initializers/evo_extension_points.rb` in an `after_initialize`
  hook.
- `routes` — driven by `PluginLoader.draw_routes(mapper)`, called from
  `config/routes.rb` at the end of the `Rails.application.routes.draw`
  block. The `mapper` is the routing mapper (`self` of the draw block).
  Both are no-ops in the community release — the registry is empty until
  a consumer gem registers a plugin. A consumer's `Railtie`/`Engine`
  initializer MUST run before route drawing, so the `routes` callback is
  present when `draw_routes` iterates the registry.

**Breaking-change policy:** removing or renaming `register_plugin`,
`plugins`, `on_boot`, `routes`, `load_all` or `draw_routes` is a major
bump. Adding new lifecycle hooks (`on_shutdown`, `on_request_start`,
etc.) is a minor bump.

### 4. `theme_tokens`

**Version:** `2.0.0`
**Default:** returns the canonical Evolution palette and typography
tokens, regardless of `scope:`.

```ruby
EvoExtensionPoints::ThemeTokens.defaults(scope: :default) # => Hash<String, String>
```

Override:

```ruby
EvoExtensionPoints.replace(:theme_tokens) do |scope|
  MyConsumer.theme_tokens_for(scope: scope)
end
```

**Breaking-change policy:** removing or retyping a token key already
present is a major bump. Adding new token keys or new accepted `scope:`
values is a minor bump.

### 5. `data_export`

**Version:** `2.0.0`
**Default:** the community release registers nothing;
`exportable_tables_for_scope` returns `[]`.

```ruby
EvoExtensionPoints::DataExport.register(name:, &scope_block)
EvoExtensionPoints::DataExport.exportable_tables_for_scope(scope_id)
  # => [{ name: Symbol, records: Enumerable }]
```

The scope block is the consumer's responsibility; the community never
reads consumer data on its behalf.

**Breaking-change policy:** renaming `register` / `exportable_tables_for_scope`,
or changing the shape of the returned entries, is a major bump.

---

### 6. `permission_resolver`

**Version:** `2.1.0`
**Default:** delegates to the auth-service exactly as before —
`EvoAuthService#check_user_permission(user_id, permission_key)` — so a
community install behaves identically with or without a consumer.

```ruby
EvoExtensionPoints::PermissionResolver.allowed?(user_id:, permission_key:, **context)
  # => true / false

EvoExtensionPoints.replace(:permission_resolver) do |user_id:, permission_key:, scope_id: nil, **|
  MyConsumer.permission_allowed?(user_id, scope_id, permission_key)
end
```

Consumers receive the full keyword context (currently `scope_id`, the
active scope bound by the consumer's own middleware; `nil` in community)
and MUST return a boolean. This seam is NOT the `capability_gate`: that
one gates capabilities/modules and defaults to allow — routing
permission checks through it would open a community install up.

**Breaking-change policy:** renaming `allowed?`, dropping a context key
already passed, or changing the default away from the auth-service
delegation is a major bump.

---

## How to use as a consumer

A consumer wires its replacements once, from a `Railtie` or `Engine`
initializer, and never patches files inside `evo-ai-crm-community`:

```ruby
require "evo_extension_points"

module MyConsumer
  class Railtie < ::Rails::Railtie
    initializer "my_consumer.extension_points" do
      EvoExtensionPoints.replace(:capability_gate) do |name, **ctx|
        MyConsumer.capability_enabled?(name, **ctx)
      end

      EvoExtensionPoints.replace(:runtime_context_current_id) { MyConsumer::Current.scope_id }
      EvoExtensionPoints.replace(:runtime_context_with_scope) do |id, &block|
        MyConsumer::Current.set(scope_id: id, &block)
      end

      EvoExtensionPoints.replace(:theme_tokens) { |scope| MyConsumer.theme_tokens_for(scope: scope) }

      EvoExtensionPoints::PluginLoader.register_plugin(:my_consumer) do |plugin|
        plugin.routes { |mapper| mapper.mount MyConsumer::Engine => "/my_consumer" }
      end
    end
  end
end
```

A consumer is expected to declare the community version range it
supports in its own package metadata (gemspec / `package.json` /
`go.mod`). A CI workflow (`community-with-extension-consumer-stub`) runs a neutral
consumer stub against every community PR, failing the build on a
contract break.

---

## Versioning history

- `2.1.0` — Added `permission_resolver` (account/scope-aware
  permission seam; default preserves the auth-service delegation).
- `2.0.0` — Renamed extension points to neutral open-core vocabulary:
  `feature_gate` → `capability_gate`, `tenant_context` → `runtime_context`
  (with `current_scope_id` / `with_scope`), `data_export` operates on a
  generic `scope_id` instead of a tenant id. Aggregate contract version
  now exposed via `EvoExtensionPoints::EXTENSION_POINTS_VERSION`.
- `1.0.0` — Initial contract.
