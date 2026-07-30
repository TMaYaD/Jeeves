# Jeeves — Infrastructure

Local development stack using Docker Compose, plus the server-version
computation Backend CD runs (`ci/`).

## Services

| Service    | Port  | Description                                        |
|------------|-------|----------------------------------------------------|
| postgres   | 5432  | PostgreSQL — the op log and the server-owned tables |
| backend    | 8000  | FastAPI service                                    |
| redis      | 6379  | Auth nonce/rate-limit counters, escrow and member-auth state |

## Start

```bash
cd infra
# Optional: set a custom secret key (defaults to insecure-dev-key for local dev)
export SECRET_KEY=your-dev-secret
docker compose up -d
```

## Run migrations

```bash
cd backend
alembic upgrade head
```

## Verify the backend is up

```bash
curl http://localhost:8000/health
```

The response carries the running `SERVER_VERSION` — the check that distinguishes
"deployed" from "working" after a release.

## Stop

```bash
docker compose down
# To also remove volumes (destroys data):
docker compose down -v
```

## One-time PowerSync replication-slot cleanup

Alembic 0034 drops the `powersync` publication, but a publication and a
replication slot are separate objects: `DROP PUBLICATION` leaves the slot
behind, and destroying the PowerSync Dokku app does not drop it either. An
orphaned logical slot has no consumer and reserves WAL for ever, so it must be
dropped by hand — once per database that ever ran PowerSync.

**Production**, immediately after the deploy that carries 0034 (the Dokku
Postgres service still runs `wal_level=logical`, so the drop needs no restart):

```bash
dokku postgres:connect jeeves-db
```

```sql
SELECT slot_name, wal_status, pg_size_pretty(
  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;
SELECT pg_drop_replication_slot('powersync');
```

**Local dev** with a persisted `postgres_data` volume needs the extra step,
because this stack's compose no longer passes `wal_level=logical`: Postgres
refuses to start while a logical slot exists under a lower `wal_level`, exiting
with `FATAL: logical replication slot "powersync" exists, but "wal_level" <
"logical"`. Bring it up once on the old setting, drop the slot, then go back:

```bash
podman compose run --rm --no-deps -d --name pg-slotfix postgres \
  postgres -c wal_level=logical -c max_replication_slots=10
timeout 30 bash -c \
  'until podman exec pg-slotfix pg_isready -U jeeves -d jeeves >/dev/null 2>&1; do sleep 1; done' \
  || { echo "pg-slotfix did not become ready within 30s" >&2; podman rm -f pg-slotfix; exit 1; }
podman exec pg-slotfix psql -U jeeves -d jeeves \
  -c "SELECT pg_drop_replication_slot('powersync')"
podman rm -f pg-slotfix
podman compose up -d postgres
```

Volumes created after #556 never had a slot; `podman compose down -v` followed by
a fresh `up` is the other way out in dev, and destroys all data.

## Recovering from schema/version drift

**Symptom:** the backend container crash-loops and `podman compose logs backend`
shows a "Schema/version drift detected" message (from `python -m app.migrate`,
the startup migration runner) or a raw `DuplicateColumnError` /
`DuplicateTableError`.

This happens when the persisted `postgres_data` volume's schema no longer
matches the revision recorded in its `alembic_version` table — e.g. after
switching branches or worktrees with divergent migration histories. The runner
deliberately never auto-stamps the version table (see
`docs/adr/0012-no-auto-stamp-on-migration-drift.md`): a schema that merely
looks migrated may genuinely be behind, and stamping it would silently skip
migrations.

Inspect the recorded revision:

```bash
podman compose exec postgres psql -U jeeves -c "SELECT version_num FROM alembic_version"
```

Recovery options, in order of preference:

1. **Stamp the revision the database actually matches.** Take a backup first:

   ```bash
   podman compose exec postgres pg_dump -U jeeves jeeves > jeeves-backup.sql
   ```

   Then verify — for every migration up to and including the revision you
   intend to stamp — that both its schema changes *and* its data effects
   (backfills, data moves) are already present in the database; comparing
   schema alone can stamp past an unapplied data migration. Only after that
   review, record the revision without re-running migrations:

   ```bash
   cd backend && alembic stamp <revision>
   ```

   Restarting the backend then applies only the genuinely pending migrations.

2. **Reset the volume** (dev only — **destroys all data**):

   ```bash
   podman compose down -v
   ```

## Backend CD

`.github/workflows/backend-cd.yml` runs on every successful Backend CI on
`main`:

1. A freshness check — skip when `workflow_run.head_sha` is no longer `main`'s
   tip. Two Backend CI runs finish in whatever order their test jobs take, so a
   *successful* run need not be the *latest*; deploying a superseded one would
   force-push older code over migrations that have already run. The run for the
   newer commit deploys it.
2. `git push` to the Dokku remote, only when the commit touched `backend/`.
   Dokku's release phase runs `python -m app.migrate` (Alembic) before the new
   container takes traffic, and the push blocks until that finishes.

Migrations are therefore never hand-run, and a merge to `main` is a deploy.
There is no separate sync-rules publish step: the op log ships as ordinary
backend code (ADR-0026), so schema and sync behaviour move in the same push.

`ci/compute-server-version.sh` derives the version that push injects as
`SERVER_VERSION`, from the conventional commits since the last `server/` tag
(ADR-0029). A `!` commit or `BREAKING CHANGE:` footer bumps the inner major.
Its test harness is `ci/tests/test-compute-server-version.sh`, run by Backend
CI's `infra-shell` job alongside `shellcheck`.
