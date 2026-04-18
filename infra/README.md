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
export JEEVES_SECRET_KEY=your-dev-secret
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

## PowerSync configuration

The sync rules and auth config live in `powersync/sync-config.yaml`.
PowerSync uses the same `JEEVES_SECRET_KEY` as the backend to validate client JWTs.
Bucket storage is colocated in Postgres — no additional database is required.
