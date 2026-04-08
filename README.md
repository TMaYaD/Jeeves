# Jeeves

A productivity-focused todos app for mobile, web, and desktop.

## Architecture

- **Frontend:** Flutter (mobile + web + desktop)
- **Backend:** FastAPI (Python, async)
- **Sync:** Electric SQL (self-hosted, Postgres-native)
- **Database:** PostgreSQL

## Mono-repo layout

```
jeeves/
├── app/          # Flutter app (mobile + web + desktop)
├── backend/      # FastAPI service
├── infra/        # Docker Compose, deployment configs
├── .github/
│   └── workflows/
└── README.md
```

## Getting started

See each subdirectory for setup instructions:

- [`app/README.md`](app/README.md) — Flutter app
- [`backend/README.md`](backend/README.md) — FastAPI backend
- [`infra/README.md`](infra/README.md) — Local dev infrastructure

## Legacy

The `master` branch contains the legacy Pylons prototype and is archived in place.
