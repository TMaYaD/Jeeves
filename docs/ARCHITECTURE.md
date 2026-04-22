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
- **Sync:** PowerSync (`powersync ^2.x` Dart package) — bidirectional sync via `JeevesBackendConnector` and a self-hosted `journeyapps/powersync-service` instance.
- **Web storage:** OPFS-backed SQLite via `WebPowerSyncOpenFactory` from `package:powersync/web.dart`, using the WASM worker assets in `app/web/`.

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

## Platform I/O Adapters

Any code that opens a file, spawns a process, or calls a native OS API must be isolated behind a platform adapter using Dart's conditional import mechanism. This keeps `dart:io` out of shared provider and service code so the app compiles cleanly on web without `if (kIsWeb)` branches scattered through business logic.

### The pattern

Three files per adapter:

| File | Compiled on | Responsibility |
|---|---|---|
| `*_stub.dart` | Neither (analyser only) | Throws `UnsupportedError` — gives the analyser a type to resolve on all targets |
| `*_io.dart` | Native (dart:io) | Concrete native implementation; may import `dart:io`, `path_provider`, etc. |
| `*_web.dart` | Web (dart:html) | Concrete web implementation; may import `package:powersync/web.dart`, `dart:js_interop`, etc. |

The entry-point file uses a conditional export to pick the right implementation:

```dart
export '*_stub.dart'
    if (dart.library.io)   '*_io.dart'
    if (dart.library.html) '*_web.dart';
```

**Rule:** any new platform-specific I/O must follow this pattern. Never add `if (kIsWeb)` branches inside provider or service code — put platform divergence in the adapter file.

### Current adapters

#### `app/lib/database/powersync_storage.dart`

Opens the process-wide `PowerSyncDatabase`.

- **Native (`powersync_storage_io.dart`):** resolves a file path via `path_provider`, runs the one-shot legacy-table migration, and opens `PowerSyncDatabase(schema, path)` using the native SQLite library (`sqlite3_flutter_libs`).  This path is shared by Android, iOS, macOS, Linux, and Windows — a platform gaining divergent behaviour (e.g. encryption key from Keychain) should split its own adapter rather than branching inside `powersync_storage_io.dart`.
- **Web (`powersync_storage_web.dart`):** opens `PowerSyncDatabase.withFactory(WebPowerSyncOpenFactory(path: 'jeeves'), schema)` backed by OPFS in Chrome and IndexedDB in other browsers.

#### `app/lib/services/platform_helper.dart`

Detects whether the app is running inside an Android emulator (for API host rewriting).

- **Native (`platform_helper_io.dart`):** reads `Platform.isAndroid` from `dart:io`.
- **Web (`platform_helper.dart` stub):** always returns `false`.

### Web worker assets

`WebPowerSyncOpenFactory` requires two files to be present in `app/web/` at runtime:

| Asset | Source |
|---|---|
| `sqlite3.wasm` | PowerSync GitHub release for the pinned `powersync` version |
| `powersync_db.worker.js` | Same release |

These files are **not committed** (`app/.gitignore`).  Run `make setup` (or `tool/fetch_web_assets.sh` directly) to download them.  The script reads the exact version from `app/pubspec.lock` so the assets always match the Dart package.

### COOP / COEP headers (OPFS requirement)

OPFS and `SharedArrayBuffer` require [cross-origin isolation](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer#security_requirements).  The server must send:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

- **Development:** `flutter run -d web-server --web-header "Cross-Origin-Opener-Policy: same-origin" --web-header "Cross-Origin-Embedder-Policy: require-corp"`
- **Production:** configure in the reverse proxy or CDN in front of the Flutter web build.

## Focus Mode Execution

Focus Mode is the task execution layer activated after daily planning. Its architecture separates ephemeral timer state from durable task state.

### Routing

`/focus/active` is a top-level `GoRoute` registered **outside** the `ShellRoute`, so `AppShell` (drawer, navigation) is not rendered. The user sees only the active task. `/focus` (the daily plan list) remains inside the `ShellRoute`.

The router has a `redirect` callback that checks `planningCompletionNotifier.value`; any path starting with `/focus` redirects to `/planning` when daily planning has not been completed. `planningCompletionNotifier` is also set as `refreshListenable` so the guard re-evaluates reactively when planning state changes.

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

## Local Search

Universal search is implemented entirely client-side against the local SQLite store, with no network dependency.

### SearchDao

`lib/database/daos/search_dao.dart` — a plain Dart class (not a `@DriftAccessor`) that exposes a single `search(userId, SearchQuery)` method returning a reactive `Stream<List<SearchResult>>`.

**Query strategy:** A single Drift LEFT OUTER JOIN across `todos`, `todo_tags`, and `tags`. Drift's type-safe `readTable` / `readTableOrNull` API handles all column mapping so no manual SQL parsing is needed. Structured filters (state, energy level, time estimate, due date range) are applied as SQL WHERE clauses. Free-text search and tag-scope filtering are applied in Dart after the join, which avoids FTS5 trigger compatibility issues with PowerSync views.

**Why not FTS5?** In production, `todos` is a PowerSync-managed SQLite view. SQLite only supports `INSTEAD OF` triggers on views, not `AFTER INSERT/UPDATE/DELETE`, so the standard FTS5 content-table + trigger pattern cannot be used. LIKE + Dart-side string matching on 10k rows completes in < 10 ms in practice.

### Search models

- `lib/models/search_query.dart` — plain Dart class holding text, state set, tag-ID set, energy levels, date range, time-estimate cap, and the `includeDone` flag. No code generation required.
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

## Daily Planning State

The daily planning feature uses a mix of global `ValueNotifier` objects (for cross-widget reactivity without a Riverpod container) and `SharedPreferences` for persistence across restarts.

### Key objects

| Object | Type | Purpose |
|---|---|---|
| `planningCompletionNotifier` | `ValueNotifier<bool>` | `true` when the ritual has been completed today |
| `bannerDismissedNotifier` | `ValueNotifier<bool>` | `true` when the banner has been dismissed today |
| `DailyPlanningNotifier` | Riverpod `NotifierProvider` | Step navigation, task mutations, banner dismiss, skip/snooze |
| `PlanningSettingsNotifier` | Riverpod `NotifierProvider` | User preferences: planning time, notification/banner toggles, snooze duration |

Both `ValueNotifier` objects are initialised from `SharedPreferences` in `initPlanningCompletion()`, which is called in `main()` before `runApp`.

### Planning nudges

The ritual can no longer be auto-launched. Users are nudged through two opt-in mechanisms:

1. **`PlanningBanner`** (`lib/widgets/planning_banner.dart`) — rendered at the top of `AppShell` (all shell-hosted routes). Visible when `planningCompletionNotifier == false && !bannerDismissedNotifier && planningSettings.bannerEnabled`. Tapping navigates to `/planning`; the × button calls `DailyPlanningNotifier.dismissBannerForToday()`.

2. **Local notification** — scheduled daily at the user's configured planning time via `NotificationService.schedulePlanningReminder()`. Uses `flutter_local_notifications` `zonedSchedule` with `matchDateTimeComponents: time` so the OS re-fires it every day without app interaction. Notification actions: Open (→ `/planning`), Snooze (one-off reschedule), Skip today (cancel until tomorrow). Handled in `_handleNotificationResponse` in `main.dart`. `matchDateTimeComponents: time` means the OS reschedules the notification daily automatically — snooze cancels the repeating schedule and registers a one-off fire instead.

### SharedPreferences keys

| Key | Value | Description |
|---|---|---|
| `planning_ritual_completed_date` | `yyyy-MM-dd` | Date of last completed ritual |
| `planning_banner_dismissed_date` | `yyyy-MM-dd` | Date banner was last dismissed |
| `planning_notification_skipped_date` | `yyyy-MM-dd` | Date user hit "Skip today" |
| `planning_notification_snoozed_until` | ISO-8601 datetime | When the snoozed notification will fire |
| `planning_settings_time_hour` | `int` | Planning time hour |
| `planning_settings_time_minute` | `int` | Planning time minute |
| `planning_settings_notification_enabled` | `bool` | Notification toggle |
| `planning_settings_banner_enabled` | `bool` | Banner toggle |
| `planning_settings_default_snooze_duration` | `int` (minutes) | Default snooze duration |

## Sprint Timer & Resolution Protocol

The sprint execution layer implements Epic 3 / Epic 4 of the requirements. It is entirely client-side with no backend involvement; time tracking is persisted via the existing `inProgressSince` / `timeSpentMinutes` columns.

### State machine extension

`GtdState.inProgress → GtdState.nextAction` is now a valid transition. This enables the "Defer" sprint resolution to atomically log elapsed time and return the task to Next Actions in a single `transitionState` call.

### SprintNotifier (`lib/providers/sprint_provider.dart`)

A plain `NotifierProvider<SprintNotifier, SprintState>` (not `autoDispose`) so the timer survives navigation.

| Phase | Meaning |
|---|---|
| `idle` | No sprint running |
| `running` | 20-min countdown active |
| `expired` | Timer hit zero — resolution required |
| `onBreak` | 3-min break between sprints |

**`startSprint(task)`**: transitions the task to `in_progress` (setting `inProgressSince`), then starts a 1-second `dart:async Timer.periodic` ticker that decrements `remainingSeconds`.

**Resolution methods:**
- `resolveComplete()` — calls `transitionState(done)`, which logs elapsed time from `inProgressSince`. Enters `onBreak` phase.
- `resolveExtend()` — keeps the task `in_progress`, restarts the 20-min countdown. Increments `sprintCount` so the UI shows "Sprint 2", "Sprint 3", etc.
- `puntTask(task)` — calls `TodoDao.unselectFromToday` to remove a task from today's plan (used with Extend).
- `resolveDefer()` — calls `TodoDao.resolveSprintDefer` which transitions `inProgress → nextAction` and clears `selectedForToday` in one transaction.

### DAO additions (`TodoDao`)

- **`resolveSprintDefer(todoId, userId)`**: wraps `transitionState(nextAction)` + clear `selectedForToday` in a single Drift transaction. The time-logging side effect happens inside `transitionState` via `_buildTransitionCompanion`.
- **`unselectFromToday(todoId, userId)`**: sets `selectedForToday = null` and `dailySelectionDate = null` without touching `state`.

### Focus screen integration (`lib/screens/focus_screen.dart`)

- Uses `ref.listen(sprintProvider, ...)` to watch for `phase == SprintPhase.expired` and immediately shows `SprintResolutionDialog` with `barrierDismissible: false`.
- A `_SprintCountdown` chip in the AppBar row shows `MM:SS` in amber (running) or green (break).
- A `_BreakBanner` strip below the header is visible during the break phase with a "Skip Break" shortcut.
- Each `_TaskRow` shows a **Sprint** button when the sprint is idle and the task is not done. The button transitions to a timer icon while that task is active.
- Partial time spent is shown inline: `"20m spent"` — derived from `Todo.timeSpentMinutes`.

### SprintResolutionDialog (`lib/screens/focus/sprint_resolution_dialog.dart`)

- Wrapped in `PopScope(canPop: false)` so back-gesture cannot dismiss it.
- Default view shows three action buttons (Complete / Extend / Defer) with a brief hint description for each.
- Tapping **Extend** switches to the **spillover matrix** view: a scrollable list of today's remaining tasks with their estimates. The user taps a task to mark it for removal; tapping "Extend & Continue" punts the selected task and restarts the timer.
- Time spent is computed as `task.timeSpentMinutes + (sprintCount × 20 min)` and shown as `"20m / 60m spent"` next to the task title.

## Navigation & Global Filter State

### Tag Cloud Navigation Filter

A sticky, multi-select context-tag filter lives in the navigation drawer and persists across screen navigation for the duration of the app session.

**State:** `TagFilterNotifier` (a `Notifier<Set<String>>` in `app/lib/providers/tag_filter_provider.dart`) holds the active set of context tag IDs.  Calling `toggle(id)` adds or removes a tag; `clear()` resets the set.  The `tagFilterProvider` is app-scoped so the state survives route changes.

**Drawer widget:** `TagCloud` (`app/lib/screens/common/tag_cloud.dart`) renders a `Wrap` of `FilterChip`s sourced from `contextTagsWithCountProvider`.  Chip visual weight (font size and opacity) scales linearly with each tag's active-task count relative to the maximum in the set.  Tags with zero active tasks are hidden unless currently selected.  Long-pressing a chip opens `TagManagementSheet` for rename/recolour/merge.

**Active filter indicator:** `_ActiveFilterBar` (embedded in `GtdListScreen`) and `_InboxFilterBar` (embedded in `InboxScreen`) show the currently selected tags as removable `InputChip`s plus a "Clear all" button.  The CONTEXTS section header in the drawer gains a count badge when any filter is active.

**DAO layer:** `TagDao.watchTagsWithActiveCount(userId, type)` uses a `customSelect` SQL query with `readsFrom: {tags, todoTags, todos}` so the count stream re-emits reactively when any of the three tables change.  Each GTD watch method in `TodoDao` and `InboxDao` accepts an optional `Set<String> tagIds` parameter; when non-empty a SQL subquery enforces AND semantics: `COUNT(DISTINCT tag_id) WHERE tag_id IN (...) = N`.

**Provider wiring:** Every GTD list provider (`nextActionsProvider`, `waitingForProvider`, `somedayMaybeProvider`, `blockedTasksProvider`, `scheduledProvider`, `inboxItemsProvider`) watches `tagFilterProvider` and passes the current tag set to its DAO method.  When the filter changes, Riverpod automatically cancels and re-subscribes the DAO stream, so the list view re-renders without any additional work in the UI layer.
