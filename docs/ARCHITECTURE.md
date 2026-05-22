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
- Seven sync shapes are replicated per user: `todos`, `tags`, `todo_tags`, `time_logs`, `focus_sessions`, `focus_session_tasks`, and `user_preferences` (all filtered by `user_id`). `focus_session_tasks` has no `user_id` column; its bucket joins through `focus_sessions` (JOIN-scoped), unlike `todo_tags` which carries a denormalized `user_id`.
- The backend issues short-lived JWTs from `GET /powersync/credentials`; PowerSync validates them using the shared `SECRET_KEY`.
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

The router has a `redirect` callback only for SWS mode (redirect `/register` to `/login`). `/focus` is unconditionally accessible from the drawer; daily planning is entered explicitly via the "Plan the Day" button on the Focus screen or the amber `FocusSessionPlanningBanner` in `AppShell`.

### Top-level routes outside the ShellRoute

| Route | Screen | Purpose |
|---|---|---|
| `/inbox/:id/clarify` | `InboxClarifyScreen` | Standalone clarification for a single inbox item; tapped from an inbox row |
| `/task/:id` | `TaskDetailScreen` | Full task detail view; reachable from Next Actions, search results, etc. |
| `/focus/active` | `ActiveFocusScreen` | Active focus timer |
| `/focus-session-planning` | `FocusSessionPlanningScreen` | Daily planning ritual |
| `/shutdown` | `ShutdownRitualScreen` | End-of-day shutdown ritual |
| `/settings` | `SettingsScreen` | App settings |
| `/search` | `SearchScreen` | Universal search |
| `/import` | `ImportScreen` | Data import |

### Inbox row tap flow

Tapping an inbox row navigates to `/inbox/:id/clarify` (`InboxClarifyScreen`), a focused, full-screen clarification flow that:

1. Loads the todo from the local DB via `TodoDao.getTodo`.
2. Shows the same editing UI as the planning wizard's `_ClarifyCard`: title, notes, energy level, time estimate, due date, and GTD routing buttons.
3. On any routing action (Next Action / Waiting For / Maybe / Done), calls the appropriate DAO method and then pops.
4. "Skip" pops without touching the DB — the item remains in the inbox.

The shared UI primitives (`ClarifyFieldLabel`, `ClarifyEnergyPicker`, `ClarifyEstimateChip`, `ClarifyDestinationButton`) live in `app/lib/widgets/clarify_shared_widgets.dart`. `InboxClarifyScreen` (the standalone full-screen flow) uses these primitives directly. The planning wizard's `InboxClarificationStep` and the periodic-review wizard's `ZeroInboxStep` instead share `ClarifyCard` (`app/lib/widgets/clarify_card.dart`), which composes the editor fields with the canonical `ProcessToHandlers` action bar described below. `ClarifyCard` also drives the periodic-review `Re-clarify…` sub-flow surfaced from the Waiting For / Next Actions / Someday-Maybe steps.

`ClarifyCard` carries a `ClarifyMode` flag (`inbox` or `reclarify`). In `inbox` mode the card unconditionally mirrors the live title into `next_action_text` when the user routes to Next or Waiting For — fresh inbox items have no deliberate phrase to lose. In `reclarify` mode the mirror is guarded: the title is written only when `next_action_text` is null/empty, so a previously-written phrase is not clobbered by a re-clarification touch.

### FocusModeNotifier (`providers/focus_session_provider.dart`)

A `NotifierProvider<FocusModeNotifier, FocusModeState>` that holds ephemeral focus session state:

- `activeTodoId` — the task currently being focused on.
- `sessionStart` — wall-clock start of the active (unpaused) segment.
- `accumulated` — total paused duration to subtract from elapsed.
- `isPaused` / `pauseStart` — pause tracking.

`elapsed` is derived: `now − sessionStart − accumulated`, frozen while paused.

State is **ephemeral** (in-memory only). The durable source of truth for the active task is `FocusSession.currentTaskId` in the DB.

Key methods:
- `startFocus(todoId)` — requires an open `FocusSession`; calls `FocusSessionDao.setCurrentTask` (which opens a `TimeLog`), then sets `sessionStart`.
- `resumeFrom(todoId, startedAt)` — restores session after restart; does not touch DB state.
- `pauseFocus()` / `resumeFocus()` — UI-only timer pause; no DB write.
- `endFocus()` — calls `FocusSessionDao.setCurrentTask(null)` to close the open `TimeLog`, then clears in-memory state.

### FocusSession model (`database/tables.dart`)

`FocusSessions` — one row per planning session. An open session (`ended_at IS NULL`) is the single source of truth for:

- The task currently being focused (`current_task_id`).
- Which tasks are on today's plan (via the `FocusSessionTasks` junction table).

`FocusSessionTasks` (`focus_session_id`, `task_id`, `position`, `disposition`) lists the ordered tasks selected during the planning ritual. The `disposition` column records the user's per-task choice made during session review (see below); `NULL` while the session is open or for done tasks.

Accessed via `FocusSessionDao` (in `database/daos/focus_session_dao.dart`):
- `openSession(userId, taskIds)` — atomically closes any prior open session and opens a new one with the given task list.
- `closeSession(sessionId)` — closes the session and any open `TimeLog`.
- `setCurrentTask(sessionId, taskId?)` — atomically closes prior `TimeLog`, opens a new one for `taskId` (if non-null), updates `current_task_id`.
- `watchActiveSession(userId)` / `getActiveSession(userId)` — stream/one-shot for the open session.
- `watchSessionTasks(sessionId)` / `watchSessionTasksForUser(userId)` — ordered task list.
- `setTaskDisposition(sessionId, taskId, disposition)` — writes a single `disposition` value; throws `StateError` if the task is not in the session.
- `reviewAndCloseSession(sessionId, dispositions, now?)` — atomic commit for session review: writes all disposition values, updates `intent = 'maybe'` for each `'maybe'` task, closes open `TimeLog`, closes session.
- `getLastClosedSessionRolloverTaskIds(userId)` — returns `task_id` values with `disposition = 'rollover'` from the most recently closed session.

### FocusSessionReview (`screens/review/`, `providers/focus_session_review_provider.dart`)

The session review screen is shown when the user taps "End Session" on `FocusScreen` and at least one task is unfinished. It lets the user assign a per-task disposition to each pending task before the session is formally closed.

**Dispositions (`models/review_disposition.dart`):**
- `rollover` — pre-select for the next planning session (task keeps `intent = 'next'`).
- `leave` — return to Next Actions without any mutation.
- `maybe` — defer; `reviewAndCloseSession` writes `intent = 'maybe'` to the todo.

**`FocusSessionReviewState`** (managed by `FocusSessionReviewNotifier`):
- `sessionTasks` — all tasks that were part of the session.
- `dispositions` — in-memory `Map<taskId, ReviewDisposition>` for pending tasks.
- `allPendingReviewed` — true when every pending task has a disposition.
- `isSubmitting` — true while the async commit is in flight.

**`FocusSessionReviewNotifier`**:
- `initFromSession(sessionId)` — loads session tasks; called once on screen mount.
- `setDisposition(taskId, disposition)` — updates the in-memory map.
- `submitReview()` — calls `dao.reviewAndCloseSession`, then sets `focusSessionPlanningCompletionNotifier.value = false`.

**Routing**: `/focus-session-review` is a top-level `GoRoute` outside the `ShellRoute`, accepting the session ID via `GoRouterState.extra`. The `FocusScreen` "End Session" button navigates here when unfinished tasks exist; if all tasks are done it calls `closeSession` directly and navigates to `/inbox`.

**Rollover pre-population**: `FocusSessionPlanningNotifier.build()` schedules `_preloadRolloverIds()` via `Future.microtask`, which queries `getLastClosedSessionRolloverTaskIds` and prepends any rollover IDs to `pendingSelectedTaskIds`. These appear pre-selected in the Plan Summary step of the next planning ritual; the user can deselect them.

### ActiveFocusScreen (`screens/active_focus_screen.dart`)

A `ConsumerStatefulWidget` with `WidgetsBindingObserver` for lifecycle events:

- **Complete**: `markDone` → `endFocus()` → snackbar with next task → `context.go('/focus')`.
- **Abandon**: `endFocus()` → `context.go('/focus')`. Task returns to Next Actions.
- **Pause/Resume**: toggled on `FocusModeNotifier` only; no DB write.
- **Exit (×)**: confirmation dialog → `pauseFocus()` → `context.go('/focus')`.

### Background Notification

When `AppLifecycleState.paused` fires during an active focus session, `NotificationService.showFocusNotification()` shows an `ongoing` Android notification (low importance, no sound). A `Timer.periodic` updates the notification body every minute. Cancelled on `AppLifecycleState.resumed`.

## Auth Provider Interface

The app supports multiple authentication backends selected at compile time.

### AuthProvider abstract interface

`app/lib/auth/auth_provider_interface.dart` defines:
- `buildLoginWidget(context)` — returns the sign-in widget for that backend.
- `signIn(params)` — performs sign-in; returns `AuthResult`.
- `signOut(refreshToken)` — revokes the server session.
- `restore()` — silently restores a session from secure storage; returns `AuthResult?`.

### AuthResult

`AuthResult` is the canonical return type for every provider sign-in:

```dart
class AuthResult {
  final String accessToken;
  final String refreshToken;
  final String userId;  // decoded from the JWT `sub` claim
}
```

`AuthNotifier` in `providers/auth_provider.dart` only deals with `AuthResult` — it never inspects JWT bytes itself.

### Compile-time mode selection

`app/lib/auth/auth_mode.dart` exposes `authImplProvider` (a Riverpod `Provider<AuthProvider>`).  The active implementation is chosen at build time:

```bash
flutter run --dart-define=JEEVES_AUTH_MODE=sws   # Sign-In With Solana
flutter run                                        # default: email + password
```

| `JEEVES_AUTH_MODE` | Implementation | File |
|---|---|---|
| `password` (default) | `PasswordAuthProvider` | `auth/password/password_auth_provider.dart` |
| `sws` | `SwsAuthProvider` | `auth/sws/sws_auth_provider.dart` |

### Adding a new auth provider

1. Create `app/lib/auth/<name>/<name>_auth_provider.dart` implementing `AuthProvider`.
2. Add a case to the `switch` in `auth_mode.dart`.
3. Pass `--dart-define=JEEVES_AUTH_MODE=<name>` at run time.

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

## Synced Preferences

`syncedPreferencesProvider` (`lib/providers/synced_preferences_provider.dart`) is the single source of truth for all user-configurable settings that should survive across devices. It is an `AsyncNotifierProvider<SyncedPreferencesNotifier, SyncedPreferences>` backed by the `user_preferences` Drift table, which PowerSync replicates from PostgreSQL.

### Storage model

All preference values are stored as JSON-encoded TEXT. A NULL value is a tombstone (treated as absent by `get`/`watch`). The `SyncedPreferences` value class provides a typed `get<T>(key)` accessor.

### One-time migration

`_migrateSharedPreferencesIfNeeded` runs on first load when the `user_preferences` table is empty. It reads two groups of keys from `SharedPreferences` and upserts them into the Drift `user_preferences` table. Settings keys are then removed from `SharedPreferences` (Drift is now the authority); ceremony keys are retained in `SharedPreferences` so cold-start init functions can read them before Riverpod loads.

**Settings keys** (cleared from SharedPreferences after migration):

| Key | Type |
|---|---|
| `focus_settings_sprint_duration_minutes` | `int` |
| `focus_settings_break_duration_minutes` | `int` |
| `focus_session_planning_settings_time_hour` | `int` |
| `focus_session_planning_settings_time_minute` | `int` |
| `focus_session_planning_settings_notification_enabled` | `bool` |
| `focus_session_planning_settings_banner_enabled` | `bool` |
| `focus_session_planning_settings_default_snooze_duration` | `int` |

**Ceremony keys** (copied to Drift but retained in SharedPreferences):

| Key | Type |
|---|---|
| `planning_banner_dismissed_date` | `String` (ISO date) |
| `planning_notification_skipped_date` | `String` (ISO date) |
| `planning_notification_snoozed_until` | `String` (ISO datetime) |
| `shutdown_ritual_completed_date` | `String` (ISO date) |
| `shutdown_banner_dismissed_date` | `String` (ISO date) |
| `shutdown_notification_skipped_date` | `String` (ISO date) |
| `shutdown_notification_snoozed_until` | `String` (ISO datetime) |

### Cross-device reactivity

`SyncedPreferencesNotifier.build()` subscribes to `dao.watchAll(userId)`. When PowerSync writes a remote change to the local `user_preferences` table, the stream fires and the in-memory state updates automatically. Providers that derive state from preferences (e.g. `focusSettingsProvider`, `focusSessionPlanningSettingsProvider`) watch `syncedPreferencesProvider` via `ref.listen` and re-derive their state on each change.

## Focus Session Planning State

The focus session planning feature uses a mix of global `ValueNotifier` objects (for cross-widget reactivity without a Riverpod container), the `user_preferences` Drift table via `syncedPreferencesProvider` (the cross-device source of truth for settings and ceremony state), and `SharedPreferences` (for cold-start reads before Riverpod loads).

### Key objects

| Object | Type | Purpose |
|---|---|---|
| `focusSessionPlanningCompletionNotifier` | `ValueNotifier<bool>` | `true` when the ritual has been completed today |
| `focusSessionPlanningBannerDismissedNotifier` | `ValueNotifier<bool>` | `true` when the banner has been dismissed today |
| `FocusSessionPlanningNotifier` | Riverpod `NotifierProvider` | Step navigation, task mutations, banner dismiss, skip/snooze |
| `FocusSessionPlanningSettingsNotifier` | Riverpod `NotifierProvider` | User preferences: planning time, notification/banner toggles, snooze duration |

`focusSessionPlanningCompletionNotifier` is set to `true` in-memory by `FocusSessionPlanningNotifier.startDay()` when the ritual ends; it is not persisted across restarts. `focusSessionPlanningBannerDismissedNotifier` is initialised from `SharedPreferences` in `initFocusSessionPlanningCompletion()`, which is called in `main()` before `runApp`.

### Inbox clarification step — snapshot+index navigation

Step 0 (`InboxClarificationStep`) uses a fixed snapshot rather than a live DB stream so the user navigates a stable, ordered list even as the underlying inbox data changes during the session.

**State fields on `FocusSessionPlanningState`:**
- `inboxNav: SnapshotNav<String>` — fixed snapshot of inbox item IDs loaded at step start (oldest-first, respecting the active tag filter), plus the current cursor.
- `inboxRoutings: Map<int, InboxRoutingRecord>` — maps snapshot index → record holding the chosen `RoutingKind`. Drives the "previously selected" affordance on revisit (the step translates to `ProcessAction` for the widget via `RoutingKind.toProcessAction()`).

**`FocusSessionPlanningNotifier` methods:**
- `loadInboxSnapshot()` — idempotent; reads the tag filter at load time, freezes the list oldest-first. Subsequent calls are no-ops.
- `nextInboxItem()` / `previousInboxItem()` — advance or retreat the cursor. `previousInboxItem()` clamps at 0 (method-level); `nextInboxItem()` has no upper-bound clamp itself — the planning screen's Next button gates further progression at `inboxIndex >= inboxSnapshot!.length` (UI-level gating).
- `skipInboxItem(id)` — records no routing; just calls `nextInboxItem()`.
- `recordInboxRoutingAndAdvance(kind)` — state-only. The DAO write is owned by `ProcessToHandlers` (see "Routing transitions" below); this method simply records the chosen `RoutingKind` in `inboxRoutings` for the current index and advances the cursor.
- `processInboxItem(id)` / `processInboxItemToWaitingFor(id)` / `processInboxItemToMaybe(id)` / `processInboxItemToDone(id)` / `processInboxItemToTrash(id)` — older bundled helpers that combine `applyRouting` and the state update. Retained because the existing test suite drives them directly; production code (`InboxClarificationStep` / `ZeroInboxStep`) uses the widget-owned write path instead.
- `getPersonTagIds(todoId)` — returns person-tag IDs for pre-seeding the person picker on a Waiting For revisit.

The **Next** button in `FocusSessionPlanningScreen` is gated on `inboxIndex >= inboxSnapshot!.length` so the user cannot advance until every item is processed or skipped. The screen also auto-advances when a freshly loaded snapshot is empty (inbox was already clear).

### Routing transitions — single source of truth

`TodoDao.applyRouting(todoId, to:, nextActionText:, personTagIds:, userId:, now:)` is the only path that mutates the `clarified` / `intent` / `done_at` / `next_action_text` columns for a clarification (inbox-clarify, re-clarification review, or any periodic-review step).

`RoutingKind` (`app/lib/models/todo.dart`) names the destinations: `nextAction`, `waitingFor`, `maybe`, `done`, `trash`. Each value defines the desired final column state (the forward matrix); `applyRouting` writes that state in a single transaction and stamps `last_clarified_at`. Because the matrix is exhaustive, callers do not need a separate revert step before re-applying.

**Orthogonality invariant (intent ⊥ delegate ⊥ user-action):** `applyRouting` writes the *intent* axis. The *delegate* axis (person tags) is mutated only when the caller explicitly passes `personTagIds` — a Next/Someday/Trash route on a delegated task does not strip the delegate, so a task can be `waiting for trixy` *and* have a new next action like `call trixy for update` without losing the delegate when the user routes it. The *user-action* axis (`next_action_text`) is written by `applyRouting` only when the caller passes `nextActionText` (typically through the `nextActionDialog` modifier or a callsite-owned setter); plain Next / Waiting For routes from `ProcessToHandlers` do not synthesise a phrase.

**Cleanup invariant on `done_at`:** any non-Done, non-Trash route clears `done_at` if set, so promoting a previously-completed task back to active state can't leave a stale completion timestamp. `Done` refreshes the timestamp; `Trash` leaves it alone so the completion record survives a soft-delete.

### `ProcessToHandlers` — the canonical "process to" action bar

`ProcessToHandlers` (`app/lib/widgets/process_to_handlers.dart`) is the single widget rendered wherever the user routes a Todo: the inbox-clarify card (planning Step 0 and weekly review's zero-inbox step), the daily planning task-review step, and the weekly review's Waiting For / Next Actions / Someday-Maybe steps.

The widget owns its DAO writes. Callsites speak `ProcessAction` (`keep`, `reclarify`, `next`, `waitingFor`, `someday`, `done`, `trash`, plus the `nextActionDialog` modifier on `next`) and never see `RoutingKind`. Callsites that hold a `RoutingKind` from a session record translate at the read site via the co-located `RoutingKind.toProcessAction()` extension. `keep` and `reclarify` have no `RoutingKind` equivalent (`keep` stamps `last_clarified_at` only; `reclarify` opens a sub-flow whose result bubbles back as the chosen routing action).

The `nextActionDialog` modifier is **on by default** — promoting a Todo to Next always opens `NextActionDialog` to capture a phrase, so a freshly-promoted task lands on the Next list with a defined action rather than re-surfacing in the daily re-clarification queue. The inbox-clarify card opts out via `except: {nextActionDialog}` because it supplies the phrase through the title-as-action coupling instead; the Next Actions weekly-review step also excepts it (it has no Next button at all).

API:

- `include: Set<ProcessAction>` — surface non-default actions (e.g. `keep`). The `nextActionDialog` modifier is default-on, so it is removed via `except`, not added via `include`.
- `except: Set<ProcessAction>` — hide default actions and the default-on `nextActionDialog` modifier (e.g. the Waiting For step uses `except: {waitingFor}` because the user is already on a waiting item, Keep covers re-confirmation; inbox-clarify uses `except: {nextActionDialog}` to keep Next as a one-tap route).
- `disabled: Set<ProcessAction>` — render disabled-state but still draw the button (parent-owned validation, e.g. inbox card disables routes while the title is empty).
- `labels: Map<ProcessAction, String>` — per-callsite label overrides.
- `lastAction: ProcessAction?` — drives the "previously selected" affordance on the matching button when the user backs up to revisit an item.
- `onAfterRoute: (ProcessAction) -> Future<void>` — fires once after a successful write (or after `keep` stamps `last_clarified_at`). Used for callsite-specific bookkeeping (advancing a snapshot cursor, recording the routing for the highlight) and for callsite-owned writes on the user-action axis — e.g. `ClarifyCard` mirrors the live title into `next_action_text` here when the user routes to Next/Waiting For from a clarify card (title-as-action coupling). Not called when the user cancels a sub-dialog.

Sub-flows owned by the widget:
- The Waiting For button opens `PersonTagPickerSheet` and writes only the intent + delegate (person tags) on confirm; `next_action_text` is on the orthogonal user-action axis and is left alone.
- The `nextActionDialog` modifier opens `NextActionDialog` (`app/lib/widgets/next_action_dialog.dart`) prefilled with the existing `next_action_text` and writes the new phrase on save — this is the only widget-internal path that mutates the user-action axis. Because the modifier is default-on, this is the standard Next behaviour everywhere except the callsites that `except` it. The weekly review's Waiting For and Someday/Maybe steps rely on it so a promotion to Next captures a phrase; their `onAfterRoute` reads the phrase back and, if the user saved it blank, stays on the item rather than advancing an actionless task onto the Next list. Promoting a delegated Waiting For item to Next keeps its person tags (intent ⊥ delegate) — `applyRouting` only touches the delegate axis when `personTagIds` is passed.
- The `Re-clarify…` button (surfaced by adding `reclarify` to `include`) pushes a full-page `ClarifyCard` route in `ClarifyMode.reclarify`. Routing inside the sub-flow is committed by the inner card's own `ProcessToHandlers`; the result is popped back to the outer widget which bubbles it through `onAfterRoute` for callsite bookkeeping (record routing, advance cursor) — the outer widget never re-writes the route. Backing out of the sub-flow without routing returns no result and is bubbled as `keep`, so the review step advances without recording a routing while keeping any field edits the user already autosaved.

### Planning nudges

The ritual can no longer be auto-launched. Users are nudged through two opt-in mechanisms:

1. **`FocusSessionPlanningBanner`** (`lib/widgets/focus_session_planning_banner.dart`) — rendered at the top of `AppShell` (all shell-hosted routes). Visible when `focusSessionPlanningCompletionNotifier == false && !focusSessionPlanningBannerDismissedNotifier && planningSettings.bannerEnabled`. Tapping navigates to `/focus-session-planning`; the × button calls `FocusSessionPlanningNotifier.dismissBannerForToday()`.

2. **Local notification** — scheduled daily at the user's configured planning time via `NotificationService.scheduleFocusSessionPlanningReminder()`. Uses `flutter_local_notifications` `zonedSchedule` with `matchDateTimeComponents: time` so the OS re-fires it every day without app interaction. Notification actions: Open (→ `/focus-session-planning`), Snooze (one-off reschedule), Skip today (cancel until tomorrow). Handled in `_handleNotificationResponse` in `main.dart`. `matchDateTimeComponents: time` means the OS reschedules the notification daily automatically — snooze schedules a one-off fire without removing the recurring daily reminder.

### Persistence

Ceremony state (banner dismissed, notification skip/snooze) is persisted to both `SharedPreferences` (for cold-start reads before Riverpod loads) and the `user_preferences` Drift table (for cross-device sync). Settings (planning time, toggles, snooze duration) are persisted exclusively to `user_preferences` via `syncedPreferencesProvider`. On cold start, `initFocusSessionPlanningNotificationSchedule()` reads planning settings from `SharedPreferences`; if not present, values default to 8:00 AM / enabled until `syncedPreferencesProvider` loads and reschedules with the values from Drift.

### SharedPreferences keys (cold-start only)

| Key | Value | Description |
|---|---|---|
| `planning_banner_dismissed_date` | `yyyy-MM-dd` | Date banner was last dismissed |
| `planning_notification_skipped_date` | `yyyy-MM-dd` | Date user hit "Skip today" |
| `planning_notification_snoozed_until` | ISO-8601 datetime | When the snoozed notification will fire |

## Evening Shutdown Ritual

The shutdown ritual reviews the day's focus session and lets the user assign a per-task disposition to each unfinished task before closing the session.

### EveningShutdownNotifier (`providers/evening_shutdown_provider.dart`)

A `NotifierProvider<EveningShutdownNotifier, EveningShutdownState>` that drives the shutdown ritual UI (steps 0–2: unfinished tasks → completed summary → confirm close).

**State fields on `EveningShutdownState`:**
- `currentStep: int` — 0-indexed step within the ritual.
- `dispositions: Map<String, String>` — maps task ID → disposition string (`'rollover'` | `'leave'` | `'maybe'`). Held in memory until `closeDay()` commits.
- `unfinishedSnapshot: List<Todo>?` — fixed snapshot of unfinished session tasks loaded at step start; `null` until loaded, `[]` if all tasks are done.
- `unfinishedIndex: int` — points at the task currently being resolved.

**Snapshot+index navigation** (same pattern as the inbox clarification step):
- `loadUnfinishedSnapshot()` — idempotent; reads `watchActiveSessionTasks().first`, filters `doneAt == null`, freezes the list. Subsequent calls are no-ops.
- `nextUnfinishedTask()` — increments `unfinishedIndex`. If the new index would reach `snapshot.length`, calls `advanceStep()` instead so the ritual proceeds automatically.
- `previousUnfinishedTask()` — decrements index (clamped at 0) and removes the in-memory disposition for the returned-to task so the user can re-choose.
- `rolloverTask(id)` / `returnToNextActions(id)` / `deferTask(id)` — each calls `_setDisposition` then `nextUnfinishedTask()`.

**Lifecycle:**
- `closeDay()` — atomically commits all accumulated dispositions via `FocusSessionDao.reviewAndCloseSession`, persists the completion date to `SharedPreferences`, flips `shutdownCompletionNotifier.value = true`, and resets state.
- `dismissBannerForToday()` / `skipShutdownToday()` / `snoozeShutdownNotification(minutes)` — banner and notification suppression helpers.

**Stream providers** driven by the active focus session:
- `completedTodayProvider` — tasks in the active session with `doneAt != null`.
- `unfinishedSelectedTodayProvider` — tasks in the active session with `doneAt == null` that have no in-memory disposition yet; used by the banner and other out-of-ritual consumers to show the remaining count.

## Weekly Review Wizard

A 5-screen ceremony surfaced when the cadence has elapsed (`now − periodic_review_last_completed_at >= 7 days`, or never completed). Internally namespaced `periodic_review`; user-visible copy reads "Weekly Review". The cadence is hardcoded at 7 days.

There is no dedicated brain-dump step in the wizard: capture happens through the inbox (share-sheet, voice, manual entry) throughout the week, so the review only needs to *clarify* the inbox, not re-elicit it.

### State (`providers/periodic_review_provider.dart`)

`PeriodicReviewNotifier` is a `NotifierProvider<PeriodicReviewNotifier, PeriodicReviewState>` whose state is transient — wiped by `completeReview()`. The provider is not auto-disposed, so navigating away mid-ceremony and back resumes the same wizard; only finishing the review clears the in-session snapshots and cursors.

**State fields** (each list-driven step uses the shared `SnapshotNav<T>` primitive from `utils/snapshot_nav.dart`):
- `currentStep: int` — 0..4.
- `inboxNav: SnapshotNav<String>` — todo IDs from the inbox.
- `waitingForNav: SnapshotNav<Todo>` — person-tagged next actions.
- `nextActionsNav: SnapshotNav<Todo>` — active next actions, excluding those that carry a person tag (those are handled by Waiting For).
- `somedayNav: SnapshotNav<Todo>` — `intent = 'maybe'` tasks.

**Disjointness invariant:** each task surfaces in at most one wizard step. The selectors are pairwise disjoint by construction — Inbox vs everything is split on `clarified`; Waiting For vs Someday and Next Actions vs Someday split on `intent`; Waiting For vs Next Actions split on whether the task carries any person-typed tag (`getNextActionsExcludingPersonTagged` enforces the exclusion in SQL). A future dedicated Projects step will need to re-establish this matrix (project-tagged ⊂ next-actions, so it would have to be ordered ahead of Next Actions or the Next Actions snapshot would have to also exclude project-tagged items).

**Snapshot loaders** are called by `_onStepEnter` each time a step is entered. Every list-driven step (Inbox, Waiting For, Next Actions, Someday/Maybe) auto-skips on entry when its snapshot loads empty — there is nothing to reflect on if the list has no items, so the wizard advances straight to the next step.

**`completeReview()`** writes the completion timestamp to synced preferences via `PeriodicReviewSettingsNotifier`, then resets the in-session state to its initial form so the next entry starts on a clean Step 0.

### Settings (`providers/periodic_review_settings_provider.dart`)

Durable state lives in `user_preferences` under the `periodic_review_*` keys; no new tables. Cross-device LWW + tombstone semantics from `syncedPreferencesProvider` ensure all devices suppress the banner on their next sync after completion. Notification skip/snooze additionally dual-write to `SharedPreferences` for cold-start reads before Riverpod loads — same pattern as the focus-session planning ceremony — so a notification suppression survives a restart even before the synced-prefs stream re-emits. The dual-write happens inside `persistPeriodicReviewSkipToday` / `persistPeriodicReviewSnoozedUntil`; `loadPeriodicReviewNotificationSuppression` reads the SharedPreferences side at startup.

| Key | Type | Purpose |
|---|---|---|
| `periodic_review_last_completed_at` | ISO-8601 datetime | Drives `isDue` |
| `periodic_review_banner_dismissed_date` | `yyyy-MM-dd` | Suppresses banner today |
| `periodic_review_banner_enabled` | `bool` (default `true`) | Banner toggle |
| `periodic_review_notification_enabled` | `bool` (default `true`) | Notification toggle |
| `periodic_review_notification_hour` | `int` (default `9`) | Reminder hour |
| `periodic_review_notification_minute` | `int` (default `0`) | Reminder minute |
| `periodic_review_notification_skipped_date` | `yyyy-MM-dd` | Suppresses today's reminder (dual-written to SharedPreferences) |
| `periodic_review_notification_snoozed_until` | ISO-8601 datetime | One-off snooze fire time (dual-written to SharedPreferences) |

Derived providers: `periodicReviewIsDueProvider`, `periodicReviewBannerDismissedTodayProvider`, `periodicReviewBannerEnabledProvider`, `periodicReviewLastCompletedProvider`.

### UI

- `screens/periodic_review/periodic_review_screen.dart` — non-swipeable `PageView` of five step pages. Step transitions go through `advanceStep` / `goToStep`, which fire the entry hook for snapshot loading.
- Footer Back / Next drive the per-step item cursor first: on a list-driven step, Next advances `inboxNav` / `waitingForNav` / `nextActionsNav` / `somedayNav` while items remain, and only crosses into the next step once the cursor has nothing more to consume (`!canGoForward`); Back symmetrically retreats the cursor before crossing back.
- Per-item steps (Waiting For, Next Actions, Someday/Maybe) share `_review_card.dart` (`ReviewItemCard`, `ReviewAction`, `ReviewEmptyState`). Each per-item step's `ProcessToHandlers` includes `ProcessAction.reclarify`, surfacing a `Re-clarify…` button that opens the full `ClarifyCard` UI as a sub-flow; routing inside the sub-flow is recorded and advances the cursor exactly like a direct tap, while backing out without routing maps to `keep` (advance without recording).
- Step 0 (Process Inbox) reuses the shared `widgets/clarify_card.dart` from the daily-planning ritual.
- `widgets/periodic_review_banner.dart` — teal banner above app-shell views. Banner toggle must be enabled, the user must have at least one todo, and dismissed-today must be false. Given those, it shows when **either** the review is due per the 7-day cadence, **or** the inbox and next-actions are both empty while waiting-for or someday/maybe still holds items. The second trigger fills the gap left by `FocusSessionPlanningBanner` (which suppresses itself in that state per #258) so the user is nudged toward the weekly review when there is nothing to plan today but deferred inventory remains. Both branches read the unfiltered list providers (`unfilteredInboxProvider`, `unfilteredNextActionsProvider`, `unfilteredWaitingForProvider`, `unfilteredMaybeProvider`) so an active context-tag filter does not change visibility.

### Notifications

`NotificationService.schedulePeriodicReviewReminder(time:)` schedules a recurring daily reminder at the configured time using `matchDateTimeComponents: time`. `_rescheduleNotification` only arms that schedule while the review is actually due (`periodicReviewIsDueProvider == true`); on completion the reschedule is triggered by the prefs listener and the schedule is canceled, so the user is not nagged daily until the cadence has elapsed again. Re-arm happens via the same listener on the next prefs write (or via `build()` the next time the notifier is constructed at app launch).

Notification actions: Open (→ `/periodic-review`), Snooze (one-off reschedule via `snoozePeriodicReviewReminder(minutes)`), Skip today (cancels only the snooze id via `skipTodayPeriodicReviewReminder()` so tomorrow's recurring reminder still fires).

## Sprint Timer (Pomodoro Engine)

Focus Mode includes an optional Pomodoro sprint timer bound to the active task. It is not a separate mode — it lives inside the Active Focus Screen as a carousel page revealed by swiping the notes view left. Sprint and break durations are user-configurable (default 20/3 min). The timer persists across app backgrounding via SharedPreferences and fires a local notification at expiry.

### Settings

`lib/models/focus_settings.dart` — `FocusSettings` value type with `sprintDurationMinutes` (default 20) and `breakDurationMinutes` (default 3).

`lib/providers/focus_settings_provider.dart` — `FocusSettingsNotifier` persists values to the `user_preferences` Drift table via `syncedPreferencesProvider` under `focus_settings_sprint_duration_minutes` and `focus_settings_break_duration_minutes`. It re-derives state from `syncedPreferencesProvider` whenever preferences change (including cross-device sync). Exposed in Settings → **FOCUS MODE**.

### State machine

`lib/providers/sprint_timer_provider.dart` — `SprintTimerNotifier` (a Riverpod `NotifierProvider<SprintTimerNotifier, SprintTimerState>`).

**Phases:**

| Phase | Duration | Description |
|---|---|---|
| `idle` | — | No sprint running |
| `focus` | configurable (default 20 min) | Active sprint, countdown running |
| `break_` | configurable (default 3 min) | Break between sprints |

**Key operations:**

- `startSprint(Todo)` — reads `focusSettingsProvider` for durations, then starts a focus sprint; triggers haptic feedback and schedules a local notification.
- `pauseSprint()` / `resumeSprint()` — freezes/resumes the remaining duration; cancels/reschedules the end notification.
- `completeSprint()` — logs the sprint duration to `todos.time_spent_minutes`, then starts the break timer.
- `stopSprint()` — cancels the timer and clears all persisted state.
- `skipBreak()` — ends the break early and records `lastBreakEndedAt`.

All mutating methods are guarded by `isProcessing: bool` to prevent rapid-tap race conditions.

### Post-break cooldown

`SprintTimerState.isPostBreakCooldown` returns `true` for `breakDurationMinutes` after a break ends (based on `lastBreakEndedAt`). While active, the Jeeves elapsed-time banner suppresses "perhaps take a break" suggestions.

### Persistence across backgrounding

When a sprint starts the notifier stores the absolute end time in `SharedPreferences`. On app resume, `_restoreFromPrefs()` reads the stored end time and recalculates the remaining duration. If the timer has already expired, the expired handler runs immediately (logs time and starts the break, or resets to idle).

**SharedPreferences keys:**

| Key | Type | Description |
|---|---|---|
| `sprint_active_task_id` | String | ID of the task being sprinted |
| `sprint_active_task_title` | String | Cached task title for restore |
| `sprint_end_time` | ISO-8601 datetime | Absolute end time of the current timer |
| `sprint_phase` | `'focus'` \| `'break'` | Current phase |
| `sprint_sprint_number` | int | 1-indexed sprint number |
| `sprint_total_sprints` | int | Total sprints for the task |
| `sprint_is_paused` | bool | Whether the timer is paused |
| `sprint_remaining_seconds` | int | Seconds remaining when paused |
| `sprint_last_break_ended_at` | ISO-8601 datetime | When the last break ended (for cooldown) |

### Notifications

Two stable notification IDs are reserved in `NotificationService`:

- `_kSprintEndNotificationId = 2` — fires when the focus sprint expires.
- `_kBreakEndNotificationId = 3` — fires when the break expires.

Both use `AndroidScheduleMode.exactAllowWhileIdle` (one-shot, not repeating), with a runtime fallback to `inexact` if `canScheduleExactNotifications()` returns false.

### Sprint count

Sprint count for a task is derived from its `timeEstimate` and the configured `sprintDurationMinutes`:

```text
totalSprints = max(1, ceil(timeEstimate / sprintDurationMinutes))
currentSprint = floor(timeSpentMinutes / sprintDurationMinutes) + 1
```

### Time tracking

When a sprint completes normally (`completeSprint`) or the timer expires while the app is backgrounded, the notifier atomically increments `time_spent_minutes` by the sprint duration in a single SQL UPDATE via Drift's `RawValuesInsertable`. The single-statement approach avoids a read-modify-write race with PowerSync's sync writes. This is best-effort: failures are silently ignored so the UI remains responsive.

### Batching suggestion

`findBatchingCandidates(List<Todo>, {int sprintMinutes = 20})` scans today's tasks for micro-tasks (estimate ≤ 15 min) and greedily selects the largest subset (sorted by estimate ascending) whose combined total fits within one sprint. If 2 or more such tasks are found, Focus Mode shows a dismissible suggestion banner. The caller passes the current `sprintDurationMinutes` from `focusSettingsProvider`.

### UI

- `lib/widgets/sprint_timer_widget.dart` — full carousel page with an idle view ("Start Sprint" button) and an active view (progress ring, MM:SS countdown, phase badge, sprint-dot indicator, playback controls).
- `lib/screens/active_focus_screen.dart` — `PageView` carousel: page 0 = notes (markdown with checkbox support), page 1 = `SprintTimerWidget`. A `_PageDots` indicator sits below the page view. Swipe left from notes to reach the sprint timer.
- `lib/screens/focus_screen.dart` — task list only; no sprint controls. Sprint count badges on task rows use `focusSettingsProvider.sprintDurationMinutes`.

## Task Domain Model

A task's lifecycle decomposes along orthogonal axes — each axis is a separate column or relation, and they combine freely. There is no `state` field; each list view is a SQL filter on these columns.

| Axis | Column / relation | Semantics |
|---|---|---|
| Clarified | `todos.clarified` (bool) | `false` = inbox item; `true` = ready to act on |
| Intent | `todos.intent` (`next` \| `maybe` \| `trash`) | What the user wants to do with this task |
| Completion | `todos.done_at` (timestamp, nullable) | Non-null = done; value = when |
| Schedule | `todos.due_date` (date, nullable) | Specific calendar date |
| PersonBlocker | `todo_tags` rows referencing a `Tag` with `type = 'person'` | Outcome is blocked on a Person; existence of the link is the block, removal is its resolution |
| Active focus | `focus_sessions.current_task_id` | Which task is currently in progress |
| Today's plan | `focus_session_tasks` rows | Membership in the open session |

A task is **actionable** when:

```text
clarified = true ∧ done_at IS NULL ∧ intent = 'next'
```

PersonBlocker is the only Blocker shape modelled today; the remaining shapes from the polymorphic-blockers design (Task / Time / Location) are tracked in TMaYaD/Jeeves#181 and are not part of this model yet.

### Waiting For list

The Waiting For list is the implicit grouping of actionable Outcomes that carry at least one `Tag(type='person')` link, grouped by the blocking Person. The List is a SQL projection — there is no `waiting_for` column and no membership table. An Outcome appears under each Person it is blocked on; an Outcome with two PersonBlockers appears twice in the grouped view, once under each Person.

The predicate that selects a row into the list is:

```sql
SELECT DISTINCT todos.*
FROM todos
JOIN todo_tags tt ON tt.todo_id = todos.id
JOIN tags tg     ON tg.id      = tt.tag_id AND tg.type = 'person'
WHERE todos.clarified = 1
  AND todos.done_at IS NULL
  AND todos.intent   = 'next'
```

`TodoDao.watchPersonTagged()` returns the flat list and `TodoDao.watchPersonTaggedGrouped()` returns it bucketed by `Tag`. Adding or removing a PersonBlocker is a Tag-link mutation on `todo_tags` — the same junction table that backs Areas, Labels, and Contexts — and stamps `last_clarified_at` on the Outcome because PersonBlocker is conceptually Clarification (it is a Blocker on the Outcome, not a categorisation), even though the storage shape looks like a Tag link.

Waiting For is disjoint from Next by construction: the Weekly Review's Next Actions snapshot excludes any Outcome carrying a person-typed tag (`TodoDao.getNextActionsExcludingPersonTagged`), and the daily re-clarification surface excludes delegated tasks from its "actionless" branch for the same reason — their cadence belongs to the weekly Waiting For review, not the daily Next list.

### Intent semantics

- `next` — normal actionable item; appears in Next / Waiting For views (Waiting For if the Outcome carries any `Tag(type='person')`, Next otherwise).
- `maybe` — deferred for later consideration; surfaces in the Maybe view; excluded from Next Actions and planning reviews.
- `trash` — marked for deletion (UX deferred; column domain enforced at DB level).

`TodoDao.setIntent(todoId, userId, intent)` writes the column. `deferTaskToMaybe` is the canonical "defer" verb.

### Internal vs UI terminology

Code names planning and review steps **session-relative** (`focus_session_planning`, `focus_session_review`), not date-relative. UI copy retains user-facing "today" / "this week" language. The split is deliberate: dates belong in copy and timezone-aware UI logic, not in entity names. `FocusSession.started_at` / `ended_at` own session lifecycle; "today" is a derived UI concept.

| Internal identifier | User-visible copy |
| :--- | :--- |
| `focus_session_planning` | "Daily Planning" |
| `focus_session` | "Focus" / "Session" |
| `evening_shutdown` | "Evening Shutdown" |
| `periodic_review` | "Weekly Review" |

The `periodic_review` namespace covers route (`/periodic-review`), provider class names, all `user_preferences` keys (`periodic_review_last_completed_at`, `periodic_review_banner_*`, `periodic_review_notification_*`), and notification action identifiers. No `weekly_review` identifier exists in code; no `periodic_review` string appears in user-visible text. The cadence is hardcoded at 7 days.

## Navigation & Global Filter State

### Tag Cloud Navigation Filter

A sticky, multi-select context-tag filter lives in the navigation drawer and persists across screen navigation for the duration of the app session.

**State:** `TagFilterNotifier` (a `Notifier<Set<String>>` in `app/lib/providers/tag_filter_provider.dart`) holds the active set of context tag IDs.  Calling `toggle(id)` adds or removes a tag; `clear()` resets the set.  The `tagFilterProvider` is app-scoped so the state survives route changes.

**Drawer widget:** `TagCloud` (`app/lib/screens/common/tag_cloud.dart`) renders a `Wrap` of `FilterChip`s sourced from `contextTagsWithCountProvider`.  Chip visual weight (font size and opacity) scales linearly with each tag's active-task count relative to the maximum in the set.  Tags with zero active tasks are hidden unless currently selected.  Long-pressing a chip opens `TagManagementSheet` for rename/recolour/merge.

**Active filter indicator:** `_ActiveFilterBar` (embedded in `GtdListScreen`) and `_InboxFilterBar` (embedded in `InboxScreen`) show the currently selected tags as removable `InputChip`s plus a "Clear all" button.  The CONTEXTS section header in the drawer gains a count badge when any filter is active.

**DAO layer:** `TagDao.watchTagsWithActiveCount(userId, type)` uses a `customSelect` SQL query with `readsFrom: {tags, todoTags, todos}` so the count stream re-emits reactively when any of the three tables change.  Each GTD watch method in `TodoDao` and `InboxDao` accepts an optional `Set<String> tagIds` parameter; when non-empty a SQL subquery enforces AND semantics: `COUNT(DISTINCT tag_id) WHERE tag_id IN (...) = N`.

**Provider wiring:** Every GTD list provider (`nextActionsProvider`, `waitingForProvider`, `maybeProvider`, `inboxItemsProvider`) watches `tagFilterProvider` and passes the current tag set to its DAO method.  When the filter changes, Riverpod automatically cancels and re-subscribes the DAO stream, so the list view re-renders without any additional work in the UI layer.
