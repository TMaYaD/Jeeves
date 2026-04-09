# Jeeves — FastAPI Backend

Async Python backend powering the Jeeves todos app.

## Stack

- **Framework:** FastAPI (async)
- **ORM:** SQLAlchemy 2 (async) + asyncpg
- **Migrations:** Alembic
- **Database:** PostgreSQL
- **Sync layer:** Electric SQL (self-hosted alongside Postgres)
- **AI:** Anthropic Python SDK (`claude-haiku-4-5-20251001` for task parsing)
- **Background tasks:** Celery + Redis

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

Start Postgres and Electric SQL first (see `../infra/`), then:

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

## Project layout

```
backend/
├── app/
│   ├── main.py         # FastAPI app, lifespan, middleware
│   ├── config.py       # Settings (pydantic-settings, env vars)
│   ├── database.py     # Async SQLAlchemy engine + session
│   ├── models/         # ORM models (Todo, List, Reminder, Location, RecurrenceRule)
│   └── api/
│       ├── health.py   # /health, /health/db
│       ├── todos.py    # /todos CRUD
│       └── ai.py       # /ai/parse, /ai/suggestions, /ai/summarize
├── alembic/
│   ├── env.py
│   └── versions/
│       └── 0001_initial_schema.py
└── alembic.ini
```
