# Jeeves — FastAPI Backend

Async Python backend powering the Jeeves app. It is a Minimal Sync Server
(ADR-0026): it authenticates Devices, appends opaque op envelopes to a
per-Workspace log, and serves them back. It holds no domain schema — the client
is the source of truth for every Task, Action, Tag and preference, and the
server never interprets an envelope's contents. See `docs/SYNC.md`.

## Stack

- **Framework:** FastAPI (async)
- **ORM:** SQLAlchemy 2 (async) + asyncpg
- **Migrations:** Alembic
- **Database:** PostgreSQL — the op log, the Member/Workspace/Grant registry,
  the identity-root escrow, and auth's own two tables. Nothing else.
- **Redis:** auth nonce and rate-limit counters, escrow and member-auth state

## Setup

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

Copy and edit the env file:

```bash
cp .env.example .env
```

## Run (development)

Start Postgres and Redis first (see `../infra/`), then:

```bash
alembic upgrade head
uvicorn app.main:app --reload
```

API docs: http://localhost:8000/docs

## Migrations

```bash
# Generate a new migration
alembic revision --autogenerate -m "describe change"

# Apply migrations
alembic upgrade head

# Rollback one step
alembic downgrade -1
```

Containerized startup (`infra/docker-compose.yml`) and the dokku release phase
(`Procfile`) run migrations via `python -m app.migrate` — a wrapper around
`alembic upgrade head` that detects schema/version drift and exits with
recovery guidance instead of an opaque `DuplicateColumnError` traceback. See
[Recovering from schema/version drift](../infra/README.md#recovering-from-schemaversion-drift).

## Project layout

Grouped by bounded context, not by layer — each package owns its own models,
schemas and routes.

```
backend/
├── app/
│   ├── main.py         # FastAPI app, lifespan, middleware, router includes
│   ├── config.py       # Settings (pydantic-settings, env vars)
│   ├── database.py     # Async SQLAlchemy engine + session
│   ├── migrate.py      # `python -m app.migrate` — drift-detecting Alembic runner
│   ├── redis.py        # Shared Redis client
│   ├── health/         # /health, /health/db
│   ├── auth/           # Users, refresh tokens, the SWS nonce/strategy providers
│   └── sync/           # The Minimal Sync Server: op log, Members, Workspaces,
│                       # Grants, recovery escrow, envelope + control payloads,
│                       # the realtime signal hub
├── alembic/
│   ├── env.py
│   └── versions/       # 0001 … 0034, applied in order by app.migrate
└── alembic.ini
```
