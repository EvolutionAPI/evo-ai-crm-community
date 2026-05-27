# Changelog

All notable changes to **evo-ai-crm-community** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **EVO-1239** — Wisper `:message_status_changed` agora é emitido por todos os providers WhatsApp (Cloud, 360-dialog, Evolution API, Evolution Go single/bulk, Baileys), Telegram (delivered + failed) e Email/SMTP (delivered + bounce DSN). Inclui novo `BounceMailbox` parseando DSN RFC 3464 (Status `5.x.x` → failed; `4.x.x` apenas logado).

### Changed

- **EVO-1239** — Telegram `send_on_telegram` passa a registrar status `delivered` após envio bem-sucedido. Read receipts não são suportados pela Bot API (Telegram limitation) e portanto `read` permanece n/a neste canal.

### Fixed

- N/A

## [v1.0.0-rc4] - 2026-05-25

Two main themes drive this release: **(1) Evolution Hub** integration as an optional proxy for Meta channels (proxy inbox creation, webhook receiver, cleanup with remote webhook deletion), and **(2) groundwork for upcoming features** not yet exposed to end users, including an internal events module foundation and listener port. Also rolls up fixes for legacy single-account assumptions, interactive-message hardening, macro execution status persistence, and Typebot interactive-button rendering.

### Added

- **Evolution Hub as an optional proxy for Meta channels** (tasks 10-18, 19-24) — wires Evolution Hub as an optional path for Meta channels (WhatsApp/Instagram/Facebook). Includes a dedicated webhook receiver, an `InboxBuilder` that creates proxy inboxes via the Hub, `hub_pending?` / `hub_active?` lifecycle on the `Channel` model, hardened validation, and cleanup that now propagates webhook deletion to the remote Hub. The feature is opt-in: when Evolution Hub is not configured, the direct Meta flow continues to work as before.
- **EVO-1088 — Macro execution status persistence + webhook failure surfacing** — macro executions now persist status (success/failure/error message) and expose failures via the webhook payload so external automations can react. Paired with the matching frontend change (real execution result in the UI).
- **Typebot interactive buttons in the agent-bot** — Typebot `choice` blocks render as interactive buttons. Paired with `evo-ai-processor-community` (#12) and `evo-ai-frontend-community`.
- **Groundwork for an internal events module** — foundation for a future CRM events module (client + payload + worker + listeners covering contact/conversation/message/pipeline). **Not user-facing in this release** — preparation for an upcoming feature, with no menu entry and no documented route.

### Changed

- **Legacy schema cleanup** — removes deprecated tables tied to features that are not yet GA in the release-candidate stream. Idempotent migration. **No impact on production data** (the dropped tables were not in use).
- **Strengthened label/conversation listeners** — F-2 of `label_list` now emits via a consistent setter, covering mutation paths that previously did not fire events. Includes specs for service paths, M1 integration, and M2 rollback.

### Fixed

- **EVO-1372 — Interactive message hardening** — payload validation, truncation of long text to Meta/WhatsApp limits, and edge-case handling (empty lists, duplicate options).
- **Legacy single-account assumptions** — internal CRM paths still dereferenced an `Account` model that was removed in earlier release-candidates. The remaining call sites have been fixed.
- **Evolution Hub — proxy inbox creation flow unblocked** — bug that prevented inboxes from being created via the Hub proxy even when configuration was valid.
- **Dead `previous_changes` branch in an event listener** — removed and documented (commit-level cleanup).
- **Internal events module hardening** — multiple post-merge review iterations on the events module (not GA), including AC closures, review follow-ups, and freezing `EVENT_NAMES` (raises `InvalidEventName` for unregistered strings).

### Upgrade notes

- This release includes a legacy schema cleanup migration. Run `db:migrate` on upgrade. **No production data is affected** — the removed tables were not in use.
- The internal events module groundwork is dormant in this release. No new environment variables, no endpoints exposed to end users. Operators only need to run `db:migrate`.

## [v1.0.0-rc3] - 2026-05-17

Stabilization release — focuses on bug fixes for payload parity with Evolution Go (buttons/lists), outbound media delivery, Notificame verify endpoint hardening, secret filtering in Rails logs, bulk actions, IDOR scope, and several automation rules fixes. Also consolidates the open-core foundation via `EXTENSION_POINTS.md` + `lib/evo_extension_points/` (no-op modules), introduces a products catalog with variants + pipeline-integrated sales, template bundle export/import (EVO-1116), and an endpoint to clear admin configuration by type.

### Added

- **Products catalog** — full products model with variants, attach to agents via a dedicated tab, and sales integrated into the pipeline (sales panel on the pipeline item).
- **Template Bundles — export & import (EVO-1116)** — configuration export and import via ZIP bundle. Lets you package inboxes, agents, automation rules, canned responses, and templates into a single file portable across installations.
- **EVO-1051 — `DELETE` endpoint to clear admin config by type** — the installation operator can reset specific configurations (SMTP, Storage, etc.) without having to edit the database.
- **EVO-1287 — CI guard-rail for the `EvoExtensionPoints` contract** (#76) — workflow that fails the PR if modules under `lib/evo_extension_points/` are modified without intentional review. Ensures the Enterprise edition can keep injecting implementations without needing a fork.
- **EVO-1286 — `lib/evo_extension_points/` with 5 no-op modules** (#75) — extension points declared as no-op modules, ready to be reopened by Enterprise. Contract versioned in `EXTENSION_POINTS.md`.
- **EVO-1283 — `EXTENSION_POINTS.md`** (#73) — document declaring 4 versioned hooks exposed by the CRM as a public extension contract.
- **EVO-1058** — `attribute_changed` operator on labels with dispatch dedup (#56). Automation rules now react to label assignment changes without firing twice for the same event.
- **EVO-1057** — listeners for `conversation_resolved` and `conversation_status_changed` (#53). Expands the automation rules trigger vocabulary to cover conversation status changes.
- **EVO-1011 — Bulk actions** — per-item result collection and response with `success_ids` / `failed_ids`, support for bulk-resolving conversations via checkbox.
- **Pipelines — `move_to_pipeline` action** — automation rules gain an action to move a conversation between pipelines while preserving the item id. Includes `pipeline_stage_updated` dedup in a 5s window per `(rule, pipeline_item, stage)` to avoid event storms.
- **Inboxes — variable expansion in message templates** — variables gain additional fields (`label`, `source`, `example`, `position`, `component`) accessible inside the template.
- **Automation rule runs — management + cleanup job** — API endpoint to query rule execution history + periodic cleanup job.
- **Action service** — new `send_canned_response` and `send_template` methods on `ActionService` (direct use by automations).
- **Regression spec** — `pipeline_item_spec` for the auto-assign-and-move flow (EVO-1080) (#57).
- **Regression spec** — Notificame verify endpoint (EVO-986).
- **Regression spec** — contact deletion with attachments (EVO-973) (#46).
- **Contract spec** — `Webhooks::Trigger` and hardening of the macros spec (EVO-1041).

### Changed

- **EVO-1113 — Credential resolution consolidated into `EvolutionConcern`** — previously the logic was spread across providers; now a single concern centralizes the per-field fallback for `api_url`, `admin_token`, and other Evolution credentials. Reduces bug surface and makes switching between Evolution API and Evolution Go easier.
- **Docs** standardized for Evolution Foundation 2026 (README, LICENSE, NOTICE, TRADEMARKS).
- **Docs (org)** — GitHub URLs updated from `EvolutionAPI` to `evolution-foundation`.
- **Schema** — comments updated on `automation_rule_run`, `role`, and `user_role`.
- **Schema** — removed unused tables and foreign keys.

### Fixed

#### Messaging — Evolution Go / Evolution API
- **EVO-1115 — buttons/lists payload for Evolution Go** (#72) — format fixed for parity with Evolution Go. Interactive messages (buttons and lists) were arriving malformed; they now follow the schema expected by both providers.
- **EVO-1151 — outbound media delivery failure** (#70) — fixed for Evolution API and Evolution Go. Outgoing attachments were not reaching the recipient in certain size/codec scenarios.
- **Duplicate messages in the Evolution Go incoming handler** — handler now deduplicates events before creating the conversation.
- **Evolution configuration fallback** — `api_url` and `admin_token` now fall back to `GlobalConfig` when per-inbox configuration is empty.

#### Notificame / Webhooks
- **EVO-986 — Notificame verify endpoint hardening** — mandatory auth, payload validation, no error leakage. The previous endpoint exposed error details useful for enumeration.
- **EVO-1041 — Macro webhook delivery failures** — macro webhook failures are now surfaced (previously they were silent). The re-raise is restricted to `:macro_webhook` to avoid retry storms on other types. Correctly wired through `ExecutionService` → `WebhookJob`.

#### Automation rules
- **EVO-1130 — Notificame attachment fallback_title** (#69) — prefers `content[:fileName]` when available to generate the attachment title.
- **EVO-1049 — BMS/Resend delivery method** (#66) — fixed delivery method symbol resolution to the correct class.
- **EVO-1011 — Bulk actions** — fixes for HIGH review findings (rounds 2 and 3), fixture spec with valid `pipeline_type` (EVO-1047).
- **`labels` condition** — now uses an `EXISTS` subquery (independent and NULL-safe), resolves UUIDs to titles with fallback, and matches a label on conversation OR contact.
- **`message_type` filter** — accepts numeric values, not just enum keys.
- **`apply_label` action** — resolves UUIDs to titles before tagging.
- **`pipeline_stage_updated`** — 5s window dedup per `(rule, pipeline_item, stage)` prevents burst firing.
- **Cross-pipeline stage movement** — correct bypass of the `same-pipeline` validation when the action is `move_to_pipeline`.
- **Action templates** — `send_template` uses `deep_stringify_keys`, improved parameters.
- **`MessageTemplateVariable`** — defined locally to avoid breaking the build.
- **Diagnostic logging** — added in `move_to_pipeline` and `pipeline_stage_updated` for investigating production issues.

#### Contacts / Pipeline
- **EVO-1018 — Group contacts** — distinguishes WhatsApp group contacts from real customer contacts; review feedback applied.

#### Media (EVO-999)
- **HIGH review findings** applied to the media fixes: `video file_type` fallback, `fallback_title` on attachments, all download paths covered.

#### Stability
- **Docker — bundler version** — pinned during installation to avoid non-deterministic builds.
- **EVO-1047** — `pipeline_item_spec` uses a valid `pipeline_type` in the fixture (previously broke the spec).

### Security

- **EVO-1111 — Secret filtering in Rails logs** — sensitive fields (`password`, `token`, `api_key`, etc.) go through Rails filter parameters before reaching the log. Previously it was possible to leak credentials in error/debug logs.
- **EVO-1084 — IDOR scope in `BulkActionsJob`** — account scope applied in the job; previously, with a valid ID from another account, it was possible to manipulate cross-tenant resources.
- **EVO-986 — Notificame verify endpoint** — mandatory auth + closed validation + no error leakage (see Fixed).

## [v1.0.0-rc2] - 2026-05-05

Stabilization release — focuses on `500 Internal Server Error` fixes on REST endpoints, Evolution Go flow fixes, per-stage automation rules, card → conversation navigation, pipeline performance, idempotent migrations for deploys on drifted schemas, `super_admin` RBAC recognized as administrator across all bypasses, and S3 signed URLs for private buckets on both WhatsApp providers.

### Added

- **EVO-989** — **Per-stage automation rules**: new feature that lets you configure `trigger → action` rules per pipeline stage. Supported triggers: `label_added`, `conversation_status_changed`, `custom_attribute_updated`. Actions: `move_to_stage`, `assign_agent`, `apply_label`. Async execution via Sidekiq with loop prevention (`Current.executed_by = :stage_automation`). Includes `Pipelines::StageAutomationService`, `PipelineStageAutomationListener`, and whitelist payload validation in the controller. (#44)
- **EVO-1007 backend** — `PipelineItemSerializer` now exposes `conversation.uuid` in the pipeline payload so the frontend can navigate directly from the card to `/conversations/<uuid>`. Scoped change (does not touch the global `ConversationSerializer`) to avoid regressions in chat. (#43)
- **EVO-1006** — search and filters added to the pipeline kanban (backend portion was already in rc1, finalized with `include_labels` along the serialization chain — #39).
- **EVO-987** — inline label creation from the "Assign Label" modal (backend support).

### Fixed

#### REST API — bugs causing 500
- **`PATCH /api/v1/pipelines/:id/pipeline_items/:id/update_custom_fields`**: `before_action :set_pipeline_item` did not cover `:update_custom_fields`, so `@pipeline_item` was `nil` and every call raised `NoMethodError`. (#32)
- **`POST /api/v1/contacts/:id/companies` raised `NoMethodError`**: `validate :must_belong_to_same_account` declared on `ContactCompany` had no implementation. Defined as `no-op` (Community is single-tenant). (#34)
- **`POST` / `DELETE /api/v1/contacts/:id/companies` returned 500 on business rule violation**: `error_response(code:, message:)` was called with kwargs incompatible with the helper signature (positional). Fixed to return 400 with a `BUSINESS_RULE_VIOLATION` envelope. (#35)
- **`/api/v1/agents/*` returned 500 / `Unauthorized`**: `current_user` was being passed as the first positional argument to `EvoAiCoreService.*_agent` (the signature expects `params` / `agent_data` / `agent_id`); additionally, `request.headers` was never forwarded, so `evo-core` received calls without a Bearer token. (#33) — *follow-up tracked in [#42](https://github.com/EvolutionAPI/evo-ai-crm-community/issues/42) to replicate the fix in the remaining controllers (`apikeys`, `folders`, etc).*
- **`GET /api/v1/oauth/applications`**: returned a raw JSON array, but the frontend expects the standard envelope `{ success, data, meta: { pagination } }`. The `/settings/integrations/oauth-apps` screen broke with `TypeError: Cannot read properties of undefined (reading 'pagination')`. (#36)
- **EVO-1000** — `POST /api/v1/team_members` returned 401 + body `{"error":"Invalid User IDs"}` for every valid UUID (the validation did `params[:user_ids].map(&:to_i)`, but `User`'s PK is a UUID — all of them became `0` and never matched). Rescue adjusted to `RecordInvalid` / `InvalidForeignKey` with a clean 422. (#24)

#### Evolution Go (EvoGo) — WhatsApp flow
- **Conversation routing — no more duplicate conversations**: when the CRM sent a message via EvoGo, the echo came back as a webhook with `IsFromMe: true`, but contact lookup was by phone number — outgoing uses LID identifier (`@lid`), so no match was found and a new conversation was created on every send. Lookup now prioritizes LID identifier and falls back to phone. (#22)
- **Correct sender type and contact lookup**: outgoing messages were being saved as `sender_type: Contact` instead of `User`. The inbox join in the contact lookup was also wrong. Fixed + reopening of pending conversations when a new message arrives. (#22)
- **Media (image / audio / video) saved without file**: 3 distinct problems fixed together: (1) `ActiveStorage#after_commit` did not fire under Sidekiq → migrated to synchronous `ActiveStorage::Blob.create_and_upload!`; (2) `mediaUrl` nested inside `imageMessage`/`audioMessage`/etc. is now extracted via `extract_media_url`; (3) EvoGo without S3 sends media as inline `base64` — added decode to `Tempfile`. (#22)
- **Audio without waveform / duration / PTT**: `configure_audio_metadata` and `audio_voice_note?` were **defined twice** in the same module (Ruby silently used the last definition, which was an incomplete stub with the wrong keys). Merged into single definitions using symbol keys. Also removed `save_message_and_notify` and `attach_media_from_url` which were dead code. (#22)
- **ActionCable — broadcast to empty token**: `account_token` returned `""` (empty string) when account was nil, and `[account_token].compact` let the empty string through, causing a broadcast to an empty channel. The function now returns `nil` (a real nil) and accepts both Hash and AR-object as input. `ActionCableBroadcastJob` also became tolerant of payloads with string or symbol keys. (#22)
- **Media in private S3 bucket returned 404 in chat**: `generate_direct_s3_url` built the public URL directly (`bucket.host/key`), but installations using Cloudflare R2 or S3 with private ACL block public access. Replaced with `presigned_url` (signed URL with short expiration) both in `whatsapp/providers/evolution_go_service.rb` (commit `316849d`) and in `whatsapp/providers/evolution_service.rb` (commit `daa9ee9` — the traditional Evolution API path was fixed afterwards with the same logic).

#### Listeners and dispatchers
- **`ContactCompanyListener`**: events were being published via `Wisper::Publisher` with `data: { ... }`, but every listener in the project reads them as `event.data[:contact]` (expecting the `Events::Base` wrapper from `SyncDispatcher`). Result: `undefined method 'data' for an instance of Hash` in the log + `CONTACT_COMPANY_LINKED` broadcast never fired. Migrated to `Rails.configuration.dispatcher.dispatch(...)` in `LinkCompanyService`, `UnlinkCompanyService`, `Contact#add_company`, and `#remove_company`; listener tolerates `account: nil` via `single_tenant_account`. (#37)
- **EVO-975** — `assign_to_default_pipeline` on conversation creation: removed `:account` from the eager loading in `pipelines_controller#fetch_pipeline` (the association does not exist in the community edition and was raising `AssociationNotFoundError`, preventing `is_default: true` from being persisted), and added detailed logging to diagnose future issues. (#26)

#### Performance and lists
- **Pipeline chip in the conversation list only appeared after tagging**: `ConversationFinder#build_conversations_query` intentionally kept the preload minimal, without `pipeline_items`. Since `ConversationSerializer` only populates the `pipelines` block when the association is loaded, the frontend received `pipelines: []` and `ConversationBadges` fell into the "no pipeline" branch. Added `pipeline_items: [:pipeline, :pipeline_stage]` to the preload — the chip now renders from the first load.

#### Serializers
- **EVO-1010** — `TeamSerializer` now includes `members_count` (running `team.team_members.count` indexed by `team_id`), fixing cards / rows that showed `0 members` even with members associated. (#25)

#### RBAC — `super_admin` recognized as administrator
When `evo-auth-service-community` introduced the `super_admin` role (see the auth changelog in this same release), the CRM's hardcoded lists still pointed only to `account_owner`, so the installation operator appeared to have no privileges in several subtle bypasses (admin mailers, admin finders, permission helpers).
- **`User#administrator?`**: now accepts both `account_owner` and `super_admin` (`app/models/concerns/user_attribute_helpers.rb`). Previously, filters like `Conversation.assignable_by` returned empty for super_admin, and the conversation list appeared empty even with a valid JWT.
- **`Role::ADMIN_ROLE_KEYS`**: new constant centralizing `%w[account_owner super_admin]`. Adopted by `AdministratorNotifications::BaseMailer#admin_emails` (installation notifications) and by every finder/scope that filtered by admin role.
- **Effect**: no endpoint needed to be changed individually — the constant consolidated what was spread across four places (commit `5f1eed2`).

#### Pipelines / Templates / Messaging (from the `develop` cycle)
- **EVO-974**: accepts a payload with nested filters, supports `pipeline_id` / `contact_id`, and `query_builder` now pairs `row + clause` to survive empty clauses.
- **EVO-1002**: `MessageTemplate#serialized` mirrors `settings.status` at the top level; template creation routes through the sync provider (Meta) and no longer flips `active` to `false` when syncing `PENDING` / `REJECTED` templates.
- **EVO-1001**: resolves label UUIDs when tagging / rendering conversations. (#14)
- **EVO-1005**: `pipeline_items#update` persists `pipeline_stage_id`. (#27)
- **EVO-1006**: `include_labels` now flows through the entire pipeline serialization chain. (#39)
- **EVO-984**: credential fallback + eager webhook for Evolution Go. (#41)
- **EVO-1055**: new endpoint `GET /api/v1/evolution/health` that proxies to `${api_url}/` of Evolution API and returns the upstream JSON. The frontend `EvolutionService.healthCheck` relied on this route to validate the configured URL before creating a WhatsApp channel; without it, every Evolution API channel creation failed with 404 and "Health check failed" with no path forward. The controller mirrors the `Net::HTTP` pattern from `authorizations_controller#check_server_status` (5s open/read timeout). (#45)
- **EVO-985**: `BACKEND_URL` pointing to `localhost` is blocked in production. (#30)
- **EVO-996**: preserves `in_reply_to` when the parent message has not yet been resolved. (#31)
- **EVO-1012**: exposes `thumbnail` and wires avatar fetch through Evolution API. (#28)
- **WhatsApp groups**: group messages are now ingested into a single conversation per group (no longer one per participant). (#29)

#### Idempotent migrations (PR #21)
Four migrations made safe for re-run in PROD with drifted schemas (or partially migrated due to a previous crash). Without this, deploys in existing environments could break with `PG::DuplicateTable` / `PG::UndefinedColumn`. Sourcery review applied with individual guards for each `add_index` / backfill (no blind early returns).
- `20251119155458_make_attachment_polymorphic.rb` — `column_exists?` guards on the polymorphic add_index.
- `20251117132621_add_type_to_contacts.rb` — `add_index` and backfill of `Contact.where(type: nil)` separated from the column guard; also creates the composite index `idx_contacts_name_type_resolved` if the `type` column already exists (cooperation with migration `20241020`).
- `20260414120000_create_user_tours.rb` — `unless table_exists?` on `create_table` + `unless index_exists?` on each `add_index`, instead of the early return that skipped indexes.
- `20251114150000_add_sentiment_analysis_fields_to_facebook_comment_moderations.rb` — `if_not_exists: true` on all added columns.

#### Migration ordering — `OptimizeContactsPerformance`
- Migration `20241020000100_optimize_contacts_performance.rb` (from PR #40) had an October/2024 timestamp — fresh installs ran it before `AddTypeToContacts` (`20251117`), trying to create an index on `contacts(name, type, id)` when the `type` column did not yet exist → `PG::UndefinedColumn`. Fix: `IF NOT EXISTS` on all `CREATE INDEX` and a `column_exists?(:contacts, :type)` guard for the composite index. `AddTypeToContacts` backfills that index after adding the column. No timestamp change (existing PROD intact).

#### Contact import / Roles (PR #40)
- **CPF/CNPJ sanitization on import** via new `sanitize_tax_id` method in `ContactManager`. Formatted CPF/CNPJ are stored with digits only.
- **Performance optimization**: `Contact.resolved_contacts` migrated to `LEFT JOIN`, count cache in the controller (1 minute), new indexes on `contact_inboxes` and `contacts`.
- **`Role` and `UserRole` models** introduced in the CRM to consume roles synchronized from `evo-auth-service` (support for role-based admin notifications).
- **`format_phone_number`** preserved the `+` prefix.
- **Import CSV** with expanded format (person/company, tax_id, social profiles, custom_attributes).

#### Database / DevOps
- **db**: dropped FKs to the removed `users` table (which were blocking `db:migrate`). (#3)
- **evolution_go**: `api_url` and `admin_token` now persist in `provider_config` from `GlobalConfig`. (#5)
- **whatsapp_cloud**: removed avatar fetch from Evolution Go on the Cloud inbound flow.

### Changed

- **CI**: workflow now also publishes `develop` images for staging.

## [v1.0.0-rc1] - 2026-04-24

### Added

- First public release candidate of `evo-ai-crm-community`.
- `Api::V1::*` REST API with controllers for conversations, contacts, pipelines, agents, OAuth applications, teams, channels, etc.
- Integration with `evo-ai-core-service` (agents) via `EvoAiCoreService`.
- Event listeners via `Wisper` + `SyncDispatcher` with broadcasts to `ActionCableListener`.
- Serializers `MessageTemplate`, `Team`, `Pipeline`, etc.
- Background jobs (`Webhooks::WhatsappEventsJob`, `ActionCableBroadcastJob`).
- Master database schema as the source of truth for setup.

---

[Unreleased]: https://github.com/evolution-foundation/evo-ai-crm-community/compare/v1.0.0-rc4...HEAD
[v1.0.0-rc4]: https://github.com/evolution-foundation/evo-ai-crm-community/compare/v1.0.0-rc3...v1.0.0-rc4
[v1.0.0-rc3]: https://github.com/evolution-foundation/evo-ai-crm-community/compare/v1.0.0-rc2...v1.0.0-rc3
[v1.0.0-rc2]: https://github.com/evolution-foundation/evo-ai-crm-community/compare/v1.0.0-rc1...v1.0.0-rc2
[v1.0.0-rc1]: https://github.com/EvolutionAPI/evo-ai-crm-community/releases/tag/v1.0.0-rc1
