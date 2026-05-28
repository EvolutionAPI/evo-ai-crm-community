<p align="center">
  <a href="https://evolutionfoundation.com.br">
    <img src="./public/hover-evolution.png" alt="Evolution Foundation" />
  </a>
</p>

<h1 align="center">Evo CRM Backend</h1>

<p align="center">
  Conversations, contacts, inboxes and messaging backend for the Evo CRM Community.
</p>

<p align="center">
  <a href="https://github.com/evolution-foundation/evo-ai-crm-community/releases/latest"><img src="https://img.shields.io/github/v/release/evolution-foundation/evo-ai-crm-community?include_prereleases&label=version&color=00ffa7" alt="Latest version" /></a>
  <a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License: Apache 2.0" /></a>
  <a href="https://docs.evolutionfoundation.com.br"><img src="https://img.shields.io/badge/Docs-evolutionfoundation.com.br-00ffa7" alt="Documentation" /></a>
  <a href="https://evolutionfoundation.com.br/community"><img src="https://img.shields.io/badge/Community-Join%20us-white" alt="Community" /></a>
</p>

<p align="center">
  <a href="https://evolutionfoundation.com.br">Website</a> &middot;
  <a href="https://docs.evolutionfoundation.com.br">Documentation</a> &middot;
  <a href="https://evolutionfoundation.com.br/community">Community</a> &middot;
  <a href="mailto:suporte@evofoundation.com.br">Support</a>
</p>

---

## About

**Evo CRM Backend** is the core API of the Evo CRM Community customer support platform. Built with Ruby on Rails 7.1 (API mode), it manages conversations, contacts, messages, inboxes, and integrations across multiple communication channels (WhatsApp, Email, Web Widget, and more).

It exposes a comprehensive RESTful API and supports real-time messaging via ActionCable WebSockets.

## Part of the Evo CRM Community

Evo CRM Backend is part of the [Evo CRM Community](https://github.com/evolution-foundation/evo-crm-community) ecosystem maintained by Evolution Foundation. To use the full stack, clone the umbrella repository with submodules:

```bash
git clone --recurse-submodules git@github.com:evolution-foundation/evo-crm-community.git
```

The Community Edition is **single-tenant** by design — one account, no multi-tenancy overhead, no super-admin, no billing or plans. All limits are removed and features are unlocked by default.

---

## Tech Stack

| Component | Technology |
|---|---|
| Backend | Ruby on Rails 7.1 (API mode) |
| Ruby | 3.4.4 |
| Database | PostgreSQL |
| Cache & Jobs | Redis + Sidekiq |
| Real-time | ActionCable (WebSocket) |
| Authentication | Bearer token via `evo-auth-service-community` |
| File storage | AWS S3, Google Cloud Storage, Azure Blob |

---

## Quick Start

### Prerequisites

- **Ruby** 3.4.4
- **PostgreSQL** 12+
- **Redis** 6+
- **pnpm** (optional, for convenience scripts)

### Installation

```bash
git clone git@github.com:evolution-foundation/evo-ai-crm-community.git
cd evo-ai-crm-community

# Install dependencies
bundle install
pnpm install  # Optional — for convenience scripts

# Setup database
bundle exec rails db:setup
bundle exec rails db:migrate
```

### Running

```bash
# Using pnpm (recommended)
pnpm dev          # Rails + Sidekiq
pnpm start        # Rails only
pnpm sidekiq      # Sidekiq only

# Using Overmind / Foreman
overmind start -f Procfile.dev

# Manual
bundle exec rails server -p 3000
bundle exec sidekiq -C config/sidekiq.yml
```

The API will be available at `http://localhost:3000`.

---

## Configuration

Copy `.env.example` to `.env` and configure:

```bash
# Database
DATABASE_URL=postgresql://localhost/evolution_crm_development

# Redis
REDIS_URL=redis://localhost:6379/0

# Optional: ScyllaDB for high-performance message storage
SCYLLA_ENABLED=true
SCYLLA_HOSTS=localhost
SCYLLA_PORT=9042
SCYLLA_KEYSPACE=evo_crm

# Frontend URL (CORS)
FRONTEND_URL=http://localhost:8080

# Storage (S3, GCS, Azure)
ACTIVE_STORAGE_SERVICE=local
```

See `.env.example` for the full list.

---

## Available Scripts

| Script | Description |
|---|---|
| `pnpm dev` | Start Rails + Sidekiq |
| `pnpm start` | Start Rails server |
| `pnpm test` | Run RSpec tests |
| `pnpm lint` | Run RuboCop |
| `pnpm lint:fix` | Run RuboCop with auto-fix |
| `pnpm db:setup` | Setup database |
| `pnpm db:migrate` | Run migrations |
| `pnpm db:seed` | Seed database |
| `pnpm console` | Rails console |
| `pnpm sidekiq` | Start Sidekiq worker |

---

## Architecture

### API-only mode

The application runs in **Rails API mode** — no frontend views. The frontend is developed separately (`evo-ai-frontend-community`).

### Service objects

Business logic is organized in service objects:

```
app/services/
├── base/
│   └── send_on_channel_service.rb
├── whatsapp/
│   └── message_processor_service.rb
└── crm/
    └── contact_sync_service.rb
```

### Event-driven (Wisper)

Domain events are published for cross-cutting concerns:
- `contact.created`
- `conversation.resolved`
- `message.sent`

### Background jobs (Sidekiq)

Heavy operations run asynchronously: external API calls, webhook processing, bulk operations.

---

## API

### Base URL

```
http://localhost:3000/api/v1
```

### Authentication

Bearer tokens issued by `evo-auth-service-community`:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
     http://localhost:3000/api/v1/conversations
```

### Documentation

Swagger UI available at `http://localhost:3000/swagger`.

For full API documentation, see [docs.evolutionfoundation.com.br](https://docs.evolutionfoundation.com.br).

---

## Features

- **Real-time** messaging via ActionCable WebSockets
- **Multi-channel** support (WhatsApp, Email, Web Widget, and more)
- **RESTful API** with comprehensive Swagger documentation
- **High-performance messages** with optional ScyllaDB (<1ms latency)
- **Background jobs** with Sidekiq
- **Event-driven** architecture for extensibility
- **File storage** support for S3, GCS, Azure Blob
- **Rich message templates** with drag-and-drop editor

---

## Testing

```bash
# All tests
pnpm test
# or
bundle exec rspec

# Specific file
bundle exec rspec spec/models/contact_spec.rb

# Specific test
bundle exec rspec spec/models/contact_spec.rb:42
```

---

## Linting

```bash
# Check
pnpm lint
# or
bundle exec rubocop

# Auto-fix
pnpm lint:fix
# or
bundle exec rubocop -a
```

---

## Docker

```bash
docker-compose build
docker-compose up

# Specific services
docker-compose up backend worker
```

---

## Documentation

| Resource | Link |
|---|---|
| Website | [evolutionfoundation.com.br](https://evolutionfoundation.com.br) |
| Documentation | [docs.evolutionfoundation.com.br](https://docs.evolutionfoundation.com.br) |
| Community | [evolutionfoundation.com.br/community](https://evolutionfoundation.com.br/community) |
| Swagger | `http://localhost:3000/swagger` |
| Changelog | [CHANGELOG.md](./CHANGELOG.md) |
| Contributing | [CONTRIBUTING.md](./CONTRIBUTING.md) |
| Security | [SECURITY.md](./SECURITY.md) |

---

## EvoFlow integration

### Canonical event names

The authoritative list is [`lib/events/evo_flow_event_names.rb`](./lib/events/evo_flow_event_names.rb) (`EvoFlow::EVENT_NAMES`, 16 dot-notation strings, frozen). `EvoFlow::PayloadBuilder.build_track` and `.build_identify` raise `EvoFlow::InvalidEventName` if a caller passes a name outside the list. The same list is mirrored in `evo-flow/src/modules/events/event-names.enum.ts`, and a CI script (`scripts/check-event-names-sync.sh` at the monorepo root) blocks PRs that drift.

**Growing the list:** adding or removing an entry requires **three coordinated edits in the same PR**: `lib/events/evo_flow_event_names.rb` (this repo), `src/modules/events/event-names.enum.ts` (in `evo-flow`), and the `EXPECTED_COUNT` constant in `scripts/check-event-names-sync.sh` (in the `evo-crm-community` monorepo). Otherwise the sync job fails with `DIVERGENT — lists match each other but count is N (expected M)`.

### Backfill EvoFlow contact_events

`EvoFlow::BackfillContactEventsWorker` ports historical `Message(message_type: :activity)` and `ReportingEvent` rows to evo-flow's ClickHouse via the `/events/batch` endpoint so the contact-events timeline (consumed by `EvoFlow::PublishEventWorker`'s downstream surface) is populated for contacts that existed before the live publisher shipped.

> ⚠️ **Do NOT run with `DRY_RUN=false` in production until evo-flow's `IdempotencyService` is deployed.** Without consumer-side dedup, reruns duplicate events in ClickHouse (`contact_events` is a plain `MergeTree`). The rake task hard-stops on `Rails.env.production? && !DRY_RUN && CONFIRM != I_KNOW_WHAT_IM_DOING` for this reason.

**1. Dry-run (default — counts and logs a single sample payload, no POST):**

```bash
bundle exec rake evo_flow:backfill                  # ALL records
bundle exec rake evo_flow:backfill DRY_RUN=true     # same, explicit
```

Watch the Sidekiq worker log for lines prefixed `[EvoFlow][Backfill]`:

- `would_backfill account=ALL type=message count=<n>` (per source)
- `sample_payload=...` (exactly one, payload of the first item)

**2. Inspect counts in ClickHouse (after a real publish):**

```sql
SELECT count() FROM contact_events WHERE message_id LIKE 'backfill|%';
```

The `messageId` is `SHA256("backfill|<source>|<id>")` and `backfill|` is the rollback selector.

**3. Real publish (dev / staging):**

```bash
DRY_RUN=false bundle exec rake evo_flow:backfill
```

**4. Real publish (production — requires CONFIRM):**

```bash
DRY_RUN=false CONFIRM=I_KNOW_WHAT_IM_DOING bundle exec rake evo_flow:backfill
```

**5. Custom date window** (default is `1.year.ago` — matches the 365-day ClickHouse TTL on `contact_events`):

```bash
FROM_DATE=2026-04-01T00:00:00Z bundle exec rake evo_flow:backfill
```

**Rollback (manual, on the evo-flow ClickHouse host):**

```sql
ALTER TABLE contact_events DELETE
WHERE message_id LIKE 'backfill|%'
  AND occurred_at >= toDateTime('2026-05-01 00:00:00');
```

**Known limitations:**

- Events older than 365 days are not iterated (matches ClickHouse TTL).
- Notes are not portable (kept in the CRM panel — out of scope).
- Without the evo-flow `IdempotencyService`, reruns duplicate events. The cursor survives crashes and is partitioned by the `from_date` window (`backfill:cursor:<yyyy-mm-dd>:message` / `…:reporting_event` in Redis::Alfred), so changing `FROM_DATE` does not silently skip records.

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines on how to submit issues, propose features, and open pull requests.

Join our [community](https://evolutionfoundation.com.br/community) to discuss ideas and collaborate.

---

## Security

For security issues, **do not open a public issue**. Email **suporte@evofoundation.com.br** or use GitHub's private vulnerability reporting. See [SECURITY.md](./SECURITY.md) for details.

---

## License

Evo CRM Backend is licensed under the Apache License 2.0. See [LICENSE](./LICENSE) for details.

## Trademarks

"Evolution Foundation", "Evolution" and "Evo CRM Backend" are trademarks of Evolution Foundation. See [TRADEMARKS.md](./TRADEMARKS.md) for the brand assets policy.

Third-party attributions are documented in [NOTICE](./NOTICE).

---

<p align="center">
  Made by <a href="https://evolutionfoundation.com.br">Evolution Foundation</a> · © 2026
</p>
