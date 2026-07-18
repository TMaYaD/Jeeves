# Jeeves — Infrastructure

Local development stack using Docker Compose.

## Services

| Service    | Port  | Description                                        |
|------------|-------|----------------------------------------------------|
| postgres   | 5432  | PostgreSQL 16 (WAL logical replication enabled)    |
| powersync  | 8080  | PowerSync sync layer (bidirectional client sync)   |
| backend    | 8000  | FastAPI service                                    |
| redis      | 6379  | Redis (Celery broker)                              |

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

## Verify PowerSync is connected

```bash
curl http://localhost:8080/api/v1/status
```

## Stop

```bash
docker compose down
# To also remove volumes (destroys data):
docker compose down -v
```

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

## PowerSync configuration

The sync rules and auth config live in `powersync/sync-config.yaml` — the
single source of truth for every environment. PowerSync uses the same
`SECRET_KEY` as the backend to validate client JWTs. Bucket storage is
colocated in Postgres — no additional database is required.

The same bytes reach each environment by a different route: locally, Compose
mounts the file at `/config` and PowerSync reads it via
`POWERSYNC_CONFIG_PATH`; in production `infra/dokku/publish-sync-config.sh`
delivers it as `POWERSYNC_CONFIG_B64` on every backend deploy, so schema
migrations and bucket definitions ship together. Production deployments mount
no config; an environment bootstrapped before ADR-0017 may still carry an inert
`/config` mount until it is removed by hand. See
[ADR-0017](../docs/adr/0017-sync-rules-as-dokku-config-var.md) and
[dokku/README.md](./dokku/README.md), which has the one-line unmount.
