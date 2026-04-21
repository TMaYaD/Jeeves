# Architecture

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

This document describes the architectural design of Jeeves, a productivity-focused todos application.

## High-Level System Overview

The system follows an offline-first architecture, allowing clients to work securely and seamlessly without an internet connection, while continuously syncing with the central database when online.

- **Frontend Clients:** Flutter-based applications supporting mobile (iOS/Android), web, and desktop.
- **Backend Service:** A Python-based FastAPI service responsible for business logic, integrations, and AI endpoints.
- **Sync Engine:** PowerSync for real-time, bidirectional replication between local embedded databases and the central PostgreSQL database.
- **Primary Database:** PostgreSQL.

### Mono-repo Structure

```text
jeeves/
├── app/          # Flutter application codebase
├── backend/      # FastAPI Python service
├── infra/        # Docker Compose and local developer environment
└── docs/         # Architecture, requirements, and design docs
```

## Architectural Principles

- **Flat, Explicit Code**: We prefer flat folder structures and explicit code flows over deep abstractions.
- **Group by Feature**: Code is organized by feature modules (e.g., Auth, Todos, Settings) rather than technical layers (Controllers, Models, Views).
- **Minimal Coupling**: Dependencies between features should be minimized to allow them to be developed, tested, and maintained independently.
- **RESTful APIs**: We prefer RESTful resources over generic actions (Ex: `POST /session` over `/login`, `POST /user` over `/register`).

## Tech Stack Details

### Frontend (Flutter)

Located in `app/`.

- **State Management:** `flutter_riverpod` and `riverpod_annotation`.
- **Local Storage:** Offline-first architecture using `drift` and `sqlite3_flutter_libs` as the structured SQL engine.
- **API Communication:** `dio` and `retrofit`.
- **Data Models:** `freezed` and `json_serializable` for robust immutable models.
- **Sync:** PowerSync (`powersync` Dart package) — bidirectional sync via `JevesBackendConnector` and a self-hosted `journeyapps/powersync-service` instance.

### Backend (Python/FastAPI)

Located in `backend/`.

- **Framework:** `fastapi` with Python 3.12+ running on `uvicorn`.
- **Database ORM:** `sqlalchemy` (with `asyncpg` for async I/O) and `alembic` for migrations.
- **Validation:** `pydantic`.
- **Background Tasks:** `celery` with `redis`.
- **AI Integrations:** `anthropic` client library.
- **Architecture:** Follows the [12-Factor App methodology](./BACKEND_GUIDELINES.md) (stateless processes, environment-based configuration, etc.).

### Sync Engine

PowerSync provides bidirectional offline-first sync between the Flutter SQLite store and PostgreSQL:

- The Flutter app connects to a self-hosted `journeyapps/powersync-service` instance.
- Three sync shapes are replicated per user: `todos`, `tags`, `todo_tags` (all filtered by `user_id`).
- The backend issues short-lived JWTs from `GET /powersync/credentials`; PowerSync validates them using the shared `JEEVES_SECRET_KEY`.
- Local writes made through the PowerSync client are queued and uploaded to the backend REST API via `JevesBackendConnector.uploadData()`.
- PowerSync uses Postgres for internal bucket storage — no additional database is required.
- Conflict resolution: last-write-wins (acceptable for v1).

## Local Search

Universal search is implemented entirely client-side against the local SQLite store, with no network dependency.

### SearchDao

`lib/database/daos/search_dao.dart` — a plain Dart class (not a `@DriftAccessor`) that exposes a single `search(userId, SearchQuery)` method returning a reactive `Stream<List<SearchResult>>`.

**Query strategy:** A single Drift LEFT OUTER JOIN across `todos`, `todo_tags`, and `tags`. Drift's type-safe `readTable` / `readTableOrNull` API handles all column mapping so no manual SQL parsing is needed. Structured filters (state, energy level, time estimate, due date range) are applied as SQL WHERE clauses. Free-text search and tag-scope filtering are applied in Dart after the join, which avoids FTS5 trigger compatibility issues with PowerSync views.

**Why not FTS5?** In production, `todos` is a PowerSync-managed SQLite view. SQLite only supports `INSTEAD OF` triggers on views, not `AFTER INSERT/UPDATE/DELETE`, so the standard FTS5 content-table + trigger pattern cannot be used. LIKE + Dart-side string matching on 10k rows completes in < 10 ms in practice.

### Search models

- `lib/models/search_query.dart` — plain Dart class holding text, state set, tag-ID set, energy levels, date range, and time-estimate cap. No code generation required.
- `lib/models/search_result.dart` — wraps a Drift `Todo` + its `List<Tag>` + a `Set<SearchMatchField>` indicating which fields matched + an optional notes snippet.

### Providers

`lib/providers/search_provider.dart`:

- `searchQueryProvider` — `NotifierProvider<SearchQueryNotifier, SearchQuery>` that the search screen writes to on each (debounced) keystroke.
- `searchResultsProvider` — `StreamProvider.autoDispose` that watches `searchQueryProvider` and delegates to `SearchDao.search`, grouping results by `GtdState`.
- `recentSearchesProvider` — `NotifierProvider<RecentSearchesNotifier, List<String>>` backed by `SharedPreferences` (max 10 entries, MRU order).

### Navigation

The search screen lives at `/search` outside the `ShellRoute` (full-screen, no drawer). It is reachable via:
- The **Search** entry in the drawer navigation (visible on every GTD list screen).
- **Ctrl+K** or **/** keyboard shortcuts registered in `AppShell` via Flutter's `Shortcuts` + `Actions` API.
