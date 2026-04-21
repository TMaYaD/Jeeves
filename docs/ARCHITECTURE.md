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

## Focus Mode Execution

Focus Mode is the task execution layer activated after daily planning. Its architecture separates ephemeral timer state from durable task state.

### Routing

`/focus/active` is a top-level `GoRoute` registered **outside** the `ShellRoute`, so `AppShell` (drawer, navigation) is not rendered. The user sees only the active task. `/focus` (the daily plan list) remains inside the `ShellRoute`.

The existing `/focus` path prefix in `_protectedPaths` also guards `/focus/active` via `startsWith`, so the route requires completed daily planning.

### FocusModeNotifier (`providers/focus_session_provider.dart`)

A `NotifierProvider<FocusModeNotifier, FocusModeState>` that holds ephemeral focus session state:

- `activeTodoId` — the task currently being focused on.
- `sessionStart` — wall-clock start of the active (unpaused) segment.
- `accumulated` — total paused duration to subtract from elapsed.
- `isPaused` / `pauseStart` — pause tracking.

`elapsed` is derived: `now − sessionStart − accumulated`, frozen while paused.

State is **ephemeral** (lost on app restart). If a task is found in `inProgress` state on app launch, the focus screen reconstructs the timer from `todo.inProgressSince` (persisted in the DB).

Key methods:
- `startFocus(todoId)` — transitions task to `inProgress` via `TodoDao.transitionState`, sets `sessionStart`.
- `resumeFrom(todoId, inProgressSince)` — restores session after restart; does not touch DB state.
- `pauseFocus()` / `resumeFocus()` — UI-only timer pause; task stays `inProgress` in the DB.
- `endFocus()` — clears all state; caller must perform the DB transition first.

### ActiveFocusScreen (`screens/active_focus_screen.dart`)

A `ConsumerStatefulWidget` with `WidgetsBindingObserver` for lifecycle events:

- **Complete**: `transitionState(done)` → `endFocus()` → snackbar with next task → `context.go('/focus')`.
- **Abandon**: `transitionState(deferred)` → `endFocus()` → `context.go('/focus')`. Task lands in `deferred` state (separate from Next Actions; user replans or skips tomorrow).
- **Pause/Resume**: toggled on `FocusModeNotifier` only; no DB write.
- **Exit (×)**: confirmation dialog → `pauseFocus()` → `context.go('/focus')`. Task stays `inProgress`; the daily plan shows a "Resume" button.

### Background Notification

When `AppLifecycleState.paused` fires during an active focus session, `NotificationService.showFocusNotification()` shows an `ongoing` Android notification (low importance, no sound). A `Timer.periodic` updates the notification body every minute. Cancelled on `AppLifecycleState.resumed`.
