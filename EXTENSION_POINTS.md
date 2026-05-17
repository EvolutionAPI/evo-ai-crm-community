# Extension Points

**Contract version:** `1.0.0` (SemVer)

This document is the public contract between `evo-ai-crm-community` and
any external consumer that wants to plug into it without forking or
patching community source. The authoritative architectural decision
behind this contract is **ADR13 — Extension Points Versioning Strategy**;
the rules below are self-contained.

The community release is fully usable on its own. Every extension point
ships with a working no-op default; a consumer can **replace** the
default implementation of one or more of them without modifying files
in `app/` or `lib/`.

If you are about to change any of the four extension points below,
read the [Compatibility Promise](#compatibility-promise) first.

---

## Compatibility Promise

Each extension point is versioned independently and treated as a public
API, with the same backward-compatibility rules as the REST `/v1/*`
endpoints:

- **Backward compatibility is forever.** Once shipped at `v1.0.0`, the
  name, arguments, return shape and observable behavior of an extension
  point do not change silently.
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

All four are exposed under the `EvoExtensionPoints` namespace,
implemented by `lib/evo_extension_points/` (delivered in a follow-up
change — until then, this document is the canonical contract).

### 1. `feature_gate`

**Version:** `1.0.0`
**Default:** always returns `true`.

```ruby
EvoExtensionPoints.feature_enabled?(flag, context = {}) # => Boolean
```

Override:

```ruby
EvoExtensionPoints.replace(:feature_gate) do |flag, context = {}|
  MyConsumer.feature_enabled?(flag, **context)
end
```

**Breaking-change policy:** renaming `feature_enabled?`, adding a
required positional argument, or changing the return type from boolean
is a major bump. Adding a new key to `context` or a new accepted
`flag` is a minor bump.

### 2. `tenant_context`

**Version:** `1.0.0`
**Default:** `tenant_id` returns `nil`; `with_tenant` yields without
binding any state (single-tenant mode).

```ruby
EvoExtensionPoints.tenant_id              # => String (UUID) | nil
EvoExtensionPoints.with_tenant(id) { ... } # => yields with tenant_id bound
```

Override:

```ruby
EvoExtensionPoints.replace(:tenant_context) do
  Module.new do
    def self.tenant_id
      MyConsumer::Current.tenant_id
    end

    def self.with_tenant(id, &block)
      MyConsumer::Current.set(tenant_id: id, &block)
    end
  end
end
```

**Breaking-change policy:** renaming `tenant_id` / `with_tenant`, or
changing the return type of `tenant_id` from `String | nil`, is a major
bump. Adding sibling helpers is a minor bump.

### 3. `plugin_loader`

**Version:** `1.0.0`
**Default:** stores registrations in memory and invokes `on_boot`
callbacks at the end of Rails boot. The community release registers
nothing on its own; `plugins` is `[]` until a consumer is installed.

```ruby
EvoExtensionPoints.register_plugin(name) do |plugin|
  plugin.on_boot { ... }
  plugin.routes { |mapper| mapper.mount(...) }
end
EvoExtensionPoints.plugins # => Array<Symbol>
```

Override (called from a consumer's `Railtie` / `Engine` initializer):

```ruby
EvoExtensionPoints.register_plugin(:my_consumer) do |plugin|
  plugin.on_boot { Rails.logger.info("[my_consumer] booted") }
  plugin.routes  { |mapper| mapper.mount MyConsumer::Engine => "/my_consumer" }
end
```

**Breaking-change policy:** removing or renaming `register_plugin`,
`plugins`, `on_boot` or `routes` is a major bump. Adding new lifecycle
hooks (`on_shutdown`, `on_request_start`, etc.) is a minor bump.

### 4. `theme_tokens`

**Version:** `1.0.0`
**Default:** returns the canonical Evolution palette and typography
tokens, regardless of `scope:`.

```ruby
EvoExtensionPoints.theme_tokens(scope: :default) # => Hash<String, String>
```

Override:

```ruby
EvoExtensionPoints.replace(:theme_tokens) do |scope: :default|
  MyConsumer.theme_tokens_for(
    tenant_id: EvoExtensionPoints.tenant_id,
    scope: scope
  )
end
```

**Breaking-change policy:** removing or retyping a token key already
present in `1.0.0` is a major bump. Adding new token keys or new
accepted `scope:` values is a minor bump.

### 5. `data_export`

**Version:** `1.0.0`
**Default:** registers nothing; `exportable_tables_for_tenant(tenant_id)`
returns `[]`.

```ruby
EvoExtensionPoints::DataExport.register(name: :widgets) do |tenant_id|
  Widget.where(tenant_id: tenant_id)
end

EvoExtensionPoints::DataExport.exportable_tables_for_tenant(tenant_id)
# => [{ name: :widgets, records: <enumerable> }]
```

The contract is a dynamic registry: an external consumer registers one
or more named scope blocks at boot, each block receiving a `tenant_id`
and returning an enumerable of records (or a query-like object the
caller can iterate). The community release ships with no registrations;
in standalone mode the registry is empty and the export is a no-op.

**Breaking-change policy:** renaming `register`,
`exportable_tables_for_tenant` or the `Entry` shape (`{ name:, records:
}`) is a major bump. Adding new optional fields to the returned entry
hash is a minor bump.

---

## How to use as a consumer

A consumer wires its replacements once, from a `Railtie` or `Engine`
initializer, and never patches files inside `evo-ai-crm-community`:

```ruby
require "evo_extension_points"

module MyConsumer
  class Railtie < ::Rails::Railtie
    initializer "my_consumer.extension_points" do
      EvoExtensionPoints.replace(:feature_gate)  { |flag, ctx = {}| MyConsumer.feature_enabled?(flag, **ctx) }
      EvoExtensionPoints.replace(:tenant_context) { MyConsumer::TenantContext }
      EvoExtensionPoints.replace(:theme_tokens)   { |scope: :default| MyConsumer.theme_tokens_for(scope: scope) }

      EvoExtensionPoints.register_plugin(:my_consumer) do |plugin|
        plugin.routes { |mapper| mapper.mount MyConsumer::Engine => "/my_consumer" }
      end
    end
  end
end
```

A consumer is expected to declare the community version range it
supports in its own package metadata (gemspec / `package.json` /
`go.mod`). A future CI workflow runs the latest consumer test suite
against every community PR, failing the build on a contract break.
