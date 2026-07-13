# Contributing to Evo CRM Backend

Thanks for your interest in contributing to Evo CRM Backend! This document
outlines how to contribute effectively.

## Code of Conduct

All contributors are expected to be respectful, inclusive, and professional.
Harassment, discrimination, or abusive behavior will not be tolerated.

## How to Contribute

### Reporting Bugs

1. Check existing [issues](https://github.com/evolution-foundation/evo-ai-crm-community/issues)
   to avoid duplicates
2. Open a new issue with:
   - Clear, descriptive title
   - Steps to reproduce
   - Expected vs actual behavior
   - Environment details (OS, version, dependencies)
   - Logs or screenshots when relevant

### Suggesting Features

1. Open an issue describing:
   - The problem you're trying to solve
   - Your proposed solution
   - Alternatives you considered
2. Wait for maintainer feedback before starting implementation

### Submitting Pull Requests

1. Fork the repository
2. Create a feature branch from `develop`:
   ```bash
   git checkout -b feat/your-feature-name
   ```
3. Make your changes following the project's coding standards
4. Write or update tests for your changes
5. Ensure all tests pass and the code lints clean
6. Commit using [Conventional Commits](https://www.conventionalcommits.org/):
   ```
   feat: add new feature
   fix: resolve bug in X
   docs: update README
   refactor: simplify Y
   test: add coverage for Z
   ```
7. Push to your fork and open a PR against `develop`
8. Fill out the PR template with context, testing notes, and screenshots if
   applicable

## Development Setup

See [README.md](./README.md) for project-specific setup instructions.

## Code Standards

- Follow the existing code style of the project
- Run linters and formatters before committing
- Add tests for new features and bug fixes
- Document public APIs and non-obvious behavior
- Keep commits atomic and focused

## Branch Strategy

- `main` — stable production-ready code
- `develop` — integration branch for upcoming releases
- `feat/*`, `fix/*`, `chore/*` — short-lived branches off `develop`

## Trademark Notice

By contributing, you agree that your contributions will be licensed under the
Apache License 2.0 (see [LICENSE](./LICENSE)). Trademarks and brand assets are
governed separately by [TRADEMARKS.md](./TRADEMARKS.md).

## Questions?

- **Community**: [evolutionfoundation.com.br/community](https://evolutionfoundation.com.br/community)
- **Documentation**: [docs.evolutionfoundation.com.br](https://docs.evolutionfoundation.com.br)
- **Email**: suporte@evofoundation.com.br

Thanks for helping make Evo CRM Backend better!

---

© 2026 Evolution Foundation

## Database migrations — version parity (EVO-2090)

This service shares a single `schema_migrations` table with
`evo-auth-service-community` (both apps point at the same database). If the two
ever create a migration with the same 14-digit version, Rails records it once
and **skips** the other app's migration forever → missing DDL → boot crash.

To make collisions impossible by construction for **new** migrations, each app
owns a **disjoint slice of the version space by parity**:

- **CRM (this repo): EVEN versions** — timestamps ending in `0/2/4/6/8`
- **auth: ODD versions** — timestamps ending in `1/3/5/7/9`

When you generate a migration, bump the timestamp by 1 second if needed so its
version is **even**.

**Enforcement:** the real gate is the `.github/workflows/migration-version-parity.yml`
workflow (`parity` job) — a lightweight filename scan that runs on every PR
without Rails/DB, since the RSpec suite is not run in full on PRs. The companion
`spec/migration_version_parity_spec.rb` documents the same rule for local runs.
For either to actually **block** a merge, its check must be marked *required* in
this repo's branch-protection settings.

**Scope of the guarantee:** parity only makes *new* (≥ cutoff) migrations
collision-free. Migrations predating the convention are grandfathered and may sit
in the other app's parity slice; the monorepo backstop
(`evo-crm-community`) catches any *exact* residual collision, but only when its
pinned submodule commits are bumped — after both PRs have already merged. Never
hand-pick an old timestamp for a new migration.

**Why not isolate `schema_migrations` per service?** That would require a backfill
on existing customer databases (a freshly-created table would re-run every
migration, breaking non-idempotent ones and the login boot). Rejected as too
risky; parity achieves the same guarantee with zero database change.
