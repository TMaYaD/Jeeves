# Jeeves — Infrastructure

Local development stack using Docker Compose.

## Services

| Service    | Port  | Description                                        |
|------------|-------|----------------------------------------------------|
| postgres   | 5432  | PostgreSQL 16 (WAL logical replication enabled)    |
| electric   | 3000  | Electric SQL sync layer                            |
| backend    | 8000  | FastAPI service                                    |
| redis      | 6379  | Redis (Celery broker)                              |

## Start

```bash
cd infra
docker compose up -d
```

## Run migrations

```bash
cd backend
alembic upgrade head
```

## Verify Electric SQL is connected

```bash
curl http://localhost:3000/v1/health
```

## Stop

```bash
docker compose down
# To also remove volumes (destroys data):
docker compose down -v
```
