# ADR-0012: Never auto-stamp the Alembic version table on schema/version drift

## Status

Accepted.

## Context

Bringing the backend up against a persisted dev volume whose schema was ahead of its `alembic_version` stamp made `alembic upgrade head` re-run migration 0024 and crash-loop on `DuplicateColumnError` — the API never bound `:8000` and the only remedy was destroying the volume (issue #382). The obvious fix is to detect "the schema already looks migrated" at startup and run `alembic stamp head` automatically.

## Decision

Startup migrations heal only provably-safe drift: an individual migration may guard its **additive** operations behind live-schema inspection (migration 0024 checks column existence before `add_column`), so re-running it no-ops and Alembic itself advances the stamp. Everything else fails loud: the startup runner (`backend/app/migrate.py`, invoked as `python -m app.migrate` by the compose command and the dokku release phase) pre-flights the version stamp against the script directory, classifies duplicate-object failures, and prints what drifted plus concrete recovery steps (back up, verify the schema and data effects of every migration up to a chosen revision, then `alembic stamp <revision>`; or reset the dev volume). It never writes the version table itself.

## Consequences

A duplicate-object error proves only that *one* object already exists, not that every pending migration was applied. Auto-stamping on that evidence would silently skip genuinely-unapplied migrations — data-loss risk the persistence policy forbids — and non-additive migrations (data moves like 0003, drops like 0020) cannot be made safely idempotent, so retroactive guards stop at 0024. The accepted cost is that non-additive drift still requires a human decision, guided by the runner's diagnostic and the recovery section in `infra/README.md`.
