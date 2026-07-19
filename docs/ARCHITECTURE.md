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
- Eleven sync shapes are replicated per user: `todos`, `tags`, `todo_tags`, `time_logs`, `focus_sessions`, `focus_session_tasks`, `focus_session_dispositions` (issue #418, ADR-0016), `user_preferences`, and the Capture split (issue #184, ADR-0006) `captures`, `capture_outcomes`, `capture_tags` — every bucket filters on `user_id` directly, since PowerSync rejects JOINs in bucket data queries as a fatal sync-rules error. The junction tables (`todo_tags`, `focus_session_tasks`, `focus_session_dispositions`, `capture_outcomes`, `capture_tags`) carry a denormalized `user_id` for this purpose (Alembic 0008, 0025, 0027, 0026). `focus_session_dispositions` is the durable home for Review Dispositions on off-Plan engaged Outcomes — Plan-member Dispositions stay on `focus_session_tasks.disposition`, keeping the Plan fixed (ADR-0002); see `docs/SYNC.md § The focus-session upload contract`. `captures` splits Capture from Outcome at the storage layer (Inbox = `captures.clarified_at IS NULL`); Alembic 0026 non-destructively moves the old `todos.clarified = false` rows across, and `carveOutLocalInbox` does the same move on-device for users who have never signed in. The Inbox and every clarify surface now read and write these tables — see `docs/SYNC.md § The Capture-split upload contract`.
- The backend issues short-lived JWTs from `GET /powersync/credentials`; PowerSync validates them using the shared `SECRET_KEY`.
- Local writes made through the PowerSync client are queued and uploaded to the backend REST API via `JevesBackendConnector.uploadData()`.
- PowerSync uses Postgres for internal bucket storage — no additional database is required.
- Sync rules deploy with the backend. `infra/powersync/sync-config.yaml` is the only place bucket definitions exist; Backend CD pushes to Dokku (whose release phase runs Alembic) and then runs `infra/dokku/publish-sync-config.sh`, which publishes that file to the PowerSync app as `POWERSYNC_CONFIG_B64` and no-ops when it is unchanged. A migration and the buckets that read its tables therefore ship in one pipeline run rather than one shipping and the other waiting on a human. The ordering is sequential, not atomic — see ADR-0017 and `infra/dokku/README.md` for the residual window and the manual two-phase procedure destructive migrations still need.
- Conflict resolution: last-write-wins by default, with a per-key strategy registry for `user_preferences` (snooze floors use a non-regressing `maxTimestampValue` rule; list/set keys are provisioned for merge). See [SYNC.md](./SYNC.md) for the full conflict matrix, the tombstone invariant, and the PowerSync write-checkpoint behaviour.

#### Upload-error policy

A CRUD entry whose REST upload fails is classified per status code by the pure function `JevesBackendConnector.classifyUploadError` — never by a blanket "4xx is fatal" rule. PowerSync queue mechanics force a three-way choice: rethrowing keeps the entry queued but blocks every later upload behind it (head-of-line), so only genuinely transient errors retry; everything else must leave the queue loudly and losslessly.

| Status | Action | Rationale |
|---|---|---|
| no status (network / timeout) | retry | transient transport failure; entry stays queued |
| 401 | retry | `_AuthRetryInterceptor` (api_service.dart) already refreshed the token and retried once; a 401 reaching the connector means the refresh itself failed, so the entry stays queued for the next backoff cycle. Never dropped. |
| 408, 429 | retry | timeout / back-pressure; PowerSync's retry backoff resolves it |
| 5xx | retry | server fault, presumed transient |
| 404 on PATCH / DELETE | discard | the only auto-drop: the remote row is already gone; server deletion wins and the next pull converges local state. Logged. |
| 404 on PUT | dead-letter | e.g. a `todo_tags` link whose parent was deleted remotely — recorded, never silent |
| 403 | dead-letter | not user-actionable; recorded so the permission / RLS bug is fixed at the root |
| 409 | dead-letter | genuine client-unresolvable id conflict; per-table meaning below |
| 400, 422 | dead-letter | client bug — payload and response body persisted for diagnosis |
| any other 4xx | dead-letter | safe default: nothing is ever silently dropped |

**409 per table.** Every connector-facing POST create route dedupes by client-generated id, and a same-user replay upserts the submitted client-owned fields and returns the row (upsert-on-replay, [ADR-0015](./adr/0015-create-dedupe-upsert-on-replay.md); docs/SYNC.md § the create-dedupe contract), so a 409 is never a retry artifact (unrelated POST endpoints — e.g. sub-resource actions like `/todos/{id}/suggestions` — are outside this client-id dedupe semantics; the connector never uploads them, so they never reach the status classification above): for `todos`, `tags`, `user_preferences`, `focus_sessions`, `time_logs`, and `captures` it means the id belongs to another user; for the junction routes (`todo_tags`, `focus_session_tasks`, `capture_outcomes`, `capture_tags`) it means the id is already bound to a different relation. No current 409 is a merge-able both-sides-edited conflict, so entries are classified and recorded losslessly; a genuine two-sided conflict-reconciliation interface is deliberately out of scope here and tracked as follow-up work coordinated with the `user_preferences` per-key strategy registry.

**Dead letters are instrumentation, not a product surface.** A dead-lettered entry is written to the local-only `sync_dead_letters` Drift table (never replicated; capped at `GtdDatabase.syncDeadLetterCap` rows, stalest last occurrence pruned first) with the operation, table, row id, payload, status, and truncated response body. Recording is idempotent per failure — one row per distinct (table, row, operation, status), refreshed on repeats — because a batch retried after a partial failure re-uploads entries that were already dead-lettered. A non-zero count forces the existing sync indicator into its error state via `syncStatusProvider`, and every dead-letter / discard is also `debugPrint`-logged with safe metadata only (table, operation, row id, status) — payloads and response bodies stay in the local table, never in console logs, which `debugPrint` emits even in release builds. There is no user-facing retry/drop surface, by design — by the time an entry fails classification it is a deterministic failure, so resolution means fixing the root cause: a 422 is a client payload bug, a 403 is a permission bug, and 404/409 churn means a route needs idempotency work. The north star is that the dead-letter table trends toward empty.

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

The router has a `redirect` callback only for SWS mode (redirect `/register` to `/login`). `/focus` is unconditionally accessible from the drawer (entry labelled "Now" — the execution home's user-facing title; internal identifiers stay Focus, see CONTEXT.md); daily planning is entered explicitly via the "Plan the Day" button on the Focus screen or the amber `FocusSessionPlanningBanner` in `AppShell`. `/focus/active` is reached from the execution home's Start buttons and from the task detail screen's "Start focus" affordance, which engages the task with or without an open session (see `FocusModeNotifier`).

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

Ceremony routes (`/focus-session-planning`, `/shutdown`, `/periodic-review`) are entered via stackless navigation (`context.go`, notification deep-links, the nudge banners), so there is no in-app back stack to pop into. Each ceremony screen wraps its wizard in `CeremonyPopScope` (`app/lib/widgets/ceremony/ceremony_pop_scope.dart`), which gives system back well-defined semantics: it invokes the exact Back callback the active step's footer renders (retreating the per-item cursor first, then the step); when that callback is unavailable (first step, first item — or a completion screen) it exits to the execution home (`context.go('/focus')`), never to the launcher. Exiting mid-ceremony abandons the performance — the screen's dispose fires `CeremonyInProgressNotifier.exit()` (deferred to a microtask, since unmount runs while the tree is locked).

### Inbox row tap flow

Tapping an inbox row navigates to `/inbox/:id/clarify` (`InboxClarifyScreen`), a focused, full-screen clarification flow that:

1. Binds to the Capture live through `captureProvider`, and separately reads its non-person tag hints once (`CaptureDao.tagHintsForCapture`) so they can seed the new Outcome's tags. The hints stay a one-shot read — the screen renders no tag chips, so there is nothing on screen for a stream to keep in step — but the Capture itself is watched, because the screen renders it.
2. Shows an editing UI of title, notes, energy level, time estimate and due date. There is no Tags section — unlike `ClarifyCard`, this screen consumes hints as draft input only, never as editable chips.
3. Renders the canonical `ProcessToHandlers` action bar for the routing verdict (Next Action / Waiting For / Someday / Done / Discard), then saves the Capture's text edits and pops via `onAfterRoute`. The bar owns every routing write, so this screen cannot drift from the ceremony clarify surfaces.
4. Gates the four Outcome-creating routes on a non-blank title (`disabled`, with an inline `errorText` on the field). **Discard stays enabled while blank** — an unnamed fragment is exactly what a user wants to throw away — and in that case the text save is skipped entirely so the blank does not overwrite the Capture's record of *what* was discarded.
5. "Skip" pops without touching the DB — the item remains in the inbox. It is the one affordance the screen still renders itself, as a `ClarifyDestinationButton` below the bar: Skip is a nav escape hatch, not a verdict, so it has no place in the routing bar.

The shared UI primitives (`ClarifyFieldLabel`, `ClarifyEnergyPicker`, `ClarifyEstimateChip`, `ClarifyDestinationButton`) live in `app/lib/widgets/clarify_shared_widgets.dart`. `InboxClarifyScreen` uses the field primitives directly, plus `ClarifyDestinationButton` for Skip; its routing buttons come from `ProcessToHandlers`. The planning wizard's `InboxClarificationStep` and the periodic-review wizard's `ZeroInboxStep` both delegate to the shared `ClarifyStep` widget (`app/lib/widgets/ceremony/clarify_step.dart`) — literally the same class in both ceremonies. `ClarifyStep` wraps `ClarifyCard` (`app/lib/widgets/clarify_card.dart`) with inline loading/empty/completion branching, accepting ceremony-specific state (nav cursor, routings, callbacks) as constructor arguments with no hard-coded provider dependency. The completion view is the canonical `_InboxCleared` widget hard-coded inside `ClarifyStep` — the "Inbox is clear" frame is identical across ceremonies and is not parameterised. `ClarifyCard` also drives the periodic-review `Re-clarify…` sub-flow surfaced from the Waiting For / Next Actions / Someday-Maybe steps.

Both clarify surfaces bind to their subject live — `InboxClarifyScreen` and `ClarifyCard.forCapture` through `captureProvider`, `ClarifyCard.forOutcome` through `taskDetailTodoProvider` — and reconcile on every emission rather than seeding once. Reconciliation is per field and respects local edits: a field whose content still matches the value the surface last put there (seeded from the row, or saved back to it) is *clean* and takes the incoming value; anything else is an edit in progress and is left untouched. Every subject-bound surface — both clarify surfaces and `TaskDetailScreen` — renders through `AsyncSubject`, the single-row counterpart to `AsyncList`. It splits the nullable subject into the four states it can actually be in, because `value == null` conflates two unrelated ones: *loading* (local storage has not answered) shows a spinner; *error* shows the shared `ErrorSurface`, never the raw exception; *missing* (`AsyncData(null)` — local storage answered, and there is no such row) shows the missing-item surface instead of the editable body, so a vanished item cannot be routed or written to; anything else is data. An error is checked before absence, so a failed query carrying a previously-null value is never mislabelled as a delete. `AsyncList` and `AsyncSubject` render the same three non-data surfaces from `state_surfaces.dart`, so a list with no rows and a subject whose row is gone look identical — to the user they are the same thing. The missing surface carries a way out wherever the surface is its own route (`InboxClarifyScreen` → Back to Inbox, `TaskDetailScreen` → Go back); the ceremony-embedded `ClarifyCard` supplies none, because its step footer already owns Skip. All of this is reactivity to local storage and nothing more: a subject-bound surface reads a local row and has no way to tell a change made on this device from one replicated in, and does not try — which is also why the missing surface says the item is gone without claiming to know why. `clearNotes` follows from the field alone (`notes.isEmpty`) rather than from a comparison against a loaded snapshot; clearing an already-null column is a no-op, so there is nothing a snapshot would add beyond the chance to be stale.

`ClarifyCard` has two named constructors matching the ADR-0006 split: `.forCapture` (an Inbox Capture on its first pass) and `.forOutcome` (the re-clarify sub-flow). On a Capture the card unconditionally mirrors the live title into the draft's `next_action_text` when the user routes to Next or Waiting For — a first clarification has no deliberate phrase to lose, and `clarifyCaptureToOutcome` applies it as it mints the Outcome. On an Outcome the mirror is guarded: the title is written only when `next_action_text` is null/empty, so a previously-written phrase is not clobbered by a re-clarification touch.

The card's Tags section (above Energy) edits the **categorisation axes** only: a single project tag via `ProjectPickerWidget` and multiple context tags via `ContextTagPickerWidget` — the same pickers the task-detail screen uses. Both autosave through `TaskDetailNotifier` (`assignProject`/`clearProject`/`assignContextTag`/`removeContextTag`), which mutate only the `todo_tags` join table. Person tags are deliberately absent from the card: delegation is assigned exclusively through the Waiting For routing button's `PersonTagPickerSheet`, whose selection is committed by the routing write that sets intent + person tags atomically. Because context/project edits never touch `todos.intent` or person-tag join rows, the intent ⊥ delegate orthogonality invariant holds structurally — attaching a project tag to a `maybe` task leaves it `maybe`. Unlike the person-tag methods, these edits do not stamp `last_clarified_at`; the clarified moment is bound to the delegate axis, not categorisation.

### FocusModeNotifier (`providers/focus_session_provider.dart`)

A `NotifierProvider<FocusModeNotifier, FocusModeState>` that holds ephemeral focus session state:

- `activeTodoId` — the task currently being focused on.
- `sessionStart` — wall-clock time when the focus segment started.

`elapsed` is derived: `now − sessionStart`. There is no pause state here — the sprint/break rhythm (including its persistence across restarts) is owned entirely by `SprintTimerProvider`.

State is **ephemeral** (in-memory only). The durable record of the active engagement is the open `TimeLog`; for session-backed focus, `FocusSession.currentTaskId` mirrors it. Restoration after a restart re-attaches by reading the active `TimeLog` (`resumeFrom`), which covers session-backed and ad-hoc engagement alike.

Key methods:
- `startFocus(todoId)` — starts an engagement. With an open `FocusSession`, calls `FocusSessionDao.setCurrentTask` (which opens a session-attributed `TimeLog` and sets the Focus pointer — the task need not be on the Plan); with no session, opens an ad-hoc `TimeLog` directly via `TimeLogDao.openLog` (null session FK — engagement is independent of FocusSession, ADR-0005). Then sets `sessionStart`.
- `resumeFrom(todoId, startedAt)` — restores the in-memory state after a restart from the active `TimeLog`'s `started_at`; does not touch DB state.
- `endFocus()` — closes the open `TimeLog` (via `FocusSessionDao.setCurrentTask(null)` when a session is open, `TimeLogDao.closeLog` otherwise), then clears in-memory state.

### FocusSession model (`database/tables.dart`)

`FocusSessions` — one row per planning session. An open session (`ended_at IS NULL`) is the single source of truth for:

- The task currently being focused (`current_task_id`).
- Which tasks are on today's plan (via the `FocusSessionTasks` junction table).

`FocusSessionTasks` (`focus_session_id`, `task_id`, `position`, `disposition`) lists the ordered tasks selected during the planning ritual. The `disposition` column records the user's per-task choice made during session review (see below); `NULL` while the session is open or for done tasks.

Accessed via `FocusSessionDao` (in `database/daos/focus_session_dao.dart`):
- `openSession(userId, taskIds)` — atomically closes any prior open session and opens a new one with the given task list.
- `closeSession(sessionId)` — closes the session and any open `TimeLog`.
- `setCurrentTask(sessionId, taskId?)` — atomically closes prior `TimeLog`, opens a new one for `taskId` (if non-null), updates `current_task_id`. The task need not be a Plan member — the Focus may point at any Outcome being engaged (off-Plan engagement, ADR-0005); the TimeLog still attributes to the session and the Plan never auto-grows.
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

- **Done**: cancels the sprint, `markDone` → `endFocus()` → snackbar with next task → `context.go('/focus')`.
- **Stop**: cancels the sprint, `endFocus()` → `context.go('/focus')` without completing the task; it returns to the focus list.

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

### Conflict resolution

Per-key conflict strategy is defined in `services/user_preferences_conflict.dart` — a `ConflictStrategy` registry (`lww` default, `maxTimestampValue` for snooze floors, `setMerge` provisioned for future list keys) with a pure `resolvePreferenceConflict` function. `strategyForKey` resolves in three steps: an exact entry in `preferenceConflictRegistry` wins, then the `snoozed_until` suffix rule, then the `lww` default. A key may register `lww` explicitly to record that its strategy was chosen rather than inherited (`clarify_mode` does). Deletion is a tombstone (present row, NULL value), never a physical removal. During normal reconciliation a server-absent row keeps the local value; the one residual wipe path is a backend-rejected upload (SYNC.md window 3), prevented by backend idempotency — and if it does happen, the connector dead-letters the entry (payload preserved, sync indicator flags the error, debug builds assert) instead of dropping it silently. The full matrix and the PowerSync reconciliation behaviour live in [SYNC.md](./SYNC.md).

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

`SyncedPreferencesNotifier.build()` subscribes to `dao.watchAll(userId)`. When PowerSync writes a remote change to the local `user_preferences` table, the stream fires and the in-memory state updates automatically. Providers that derive state from preferences (e.g. `focusSettingsProvider`, `focusSessionPlanningSettingsProvider`, `clarifyModeProvider`) watch `syncedPreferencesProvider` via `ref.listen` and re-derive their state on each change.

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

`FocusSessionPlanningNotifier` is not auto-disposed, so exiting the ceremony mid-ritual abandons the performance but retains the working state (step, cursors, routings) in memory as a draft that seeds the next performance — "Plan the Day" (`FocusScreen._replanDay`) calls `reEnterPlanning()` to reset only when the prior performance completed (`focusSessionPlanningCompletionNotifier == true`). The draft is in-memory only and silently degrades to a fresh start after process death — accepted behaviour (CONTEXT.md § Ceremony); tests must not assert draft survival across restarts.

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
- `processInboxItem(id)` / `processInboxItemToWaitingFor(id)` / `processInboxItemToMaybe(id)` / `processInboxItemToDone(id)` / `processInboxItemToTrash(id)` — older bundled helpers that combine the `ClarificationService.clarifyToOutcome` write and the state update. Retained because the existing test suite drives them directly; production code (`InboxClarificationStep` / `ZeroInboxStep`) uses the widget-owned write path instead.
- `getPersonTagIds(todoId)` — returns person-tag IDs for pre-seeding the person picker on a Waiting For revisit.

The **Next** button in `FocusSessionPlanningScreen` is gated on `nav.isLoaded` — enabled once the snapshot has loaded. `InboxClarificationStep` delegates to `ClarifyStep` (`app/lib/widgets/ceremony/clarify_step.dart`), which handles the loading/empty/completion branching inline. The footer's Skip↔Next-step swap is controlled by `!nav.isComplete`; Skip is shown while items remain (even on the last item), and Next step appears only once the cursor passes the end.

### Routing transitions — single source of truth

Every clarification UI flow writes through `ClarificationService` (`app/lib/services/clarification_service.dart`, exposed via `clarificationServiceProvider`) — the single write path for the flow, per the issue #184 reversibility directive. The interface carries two families of write, both in CONTEXT.md's Capture/Outcome vocabulary:

- **Outcome routing** (review surfaces, and today's Inbox flows) — `clarifyToOutcome`, `promoteCaptureToOutcome`, `completeOutcome`, `stampClarified`, `updateFields`, plus the `exists` / `getPersonTagIds` reads the flows need to guard their writes. `DaoClarificationService` delegates these 1:1 to the `InboxDao` / `TodoDao` methods below.
- **Capture clarification** (ADR-0006, the split model) — `clarifyCaptureToOutcome`, `discardCapture`, `captureExists`. `clarifyCaptureToOutcome` is the create-half of clarifying a Capture: in one transaction it inserts a *new* clarified Outcome from the clarify-card draft (via `TodoDao.insertOutcome` + `applyRouting`), attaches the draft's non-person tag ids and any Waiting-For delegate, links the Capture to the Outcome (`CaptureDao.linkOutcome` — provenance), and stamps `captures.clarified_at` (1-1 mode). Re-routing a Capture (Ceremony Back → re-tap) drops the Outcome the earlier tap carved and its link, then recreates, so re-tapping never accumulates a second Outcome. Because Capture↔Outcome is many-to-many, that drop retracts only *this* Capture's claim: each Outcome is unlinked first and deleted **only if no other Capture still links to it** — an Outcome shared via merge survives, merely unlinked, so one Capture's re-route can never destroy another's clarified work. `discardCapture` is the zero-Outcome verdict: it stamps `clarified_at` and creates nothing, applying the same merge-safe cleanup so a Back→Discard leaves no orphan behind and no shared Outcome damaged. Discard never fabricates a Trash Outcome; Trash-the-List stays about Outcomes. Both write methods also re-check the Capture's existence inside their transaction, so a Capture hard-deleted between the callsite pre-check and commit rolls the mutation back rather than minting an orphan Outcome or a dangling link. These are the write path every Capture clarify surface uses: the standalone inbox-clarify screen, the daily-planning inbox step, and the Weekly Review zero-inbox step. `clarifyCaptureToOutcome` rejects `RoutingKind.trash` outright — routing a Capture to Trash is the zero-Outcome discard, so a caller that asks for a trashed Outcome fails loudly rather than leaving a phantom row on the Trash List.

Nothing outside the service may bake "Inbox is just a Todo with `clarified = false`" into a load-bearing assumption. The Capture/Outcome split has landed end to end (ADR-0006, #184): the Inbox reads `captures`, and this seam is what let the UI cutover touch only the service callsites.

`TodoDao.applyRouting(todoId, to:, nextActionText:, personTagIds:, userId:, now:)` — reached through `ClarificationService.clarifyToOutcome` — is the single source of truth for **routing verdicts**: every route the user picks on a clarify or review surface (inbox-clarify, re-clarification review, or any periodic-review step) lands in this one write. The service's other write methods delegate to their own DAO paths — `completeOutcome` → `TodoDao.markDone`, `stampClarified` → `TodoDao.stampLastClarifiedAt`, `updateFields` → `TodoDao.updateFields` — so `applyRouting` is not the sole mutator of the `clarified` / `intent` / `done_at` / `next_action_text` columns, but it is the only path that applies a `RoutingKind`.

`RoutingKind` (`app/lib/models/todo.dart`) names the destinations: `nextAction`, `waitingFor`, `maybe`, `done`, `trash`. Each value defines the desired final column state (the forward matrix); `applyRouting` writes that state in a single transaction and stamps `last_clarified_at`. Because the matrix is exhaustive, callers do not need a separate revert step before re-applying.

**Orthogonality invariant (intent ⊥ delegate ⊥ user-action):** `applyRouting` writes the *intent* axis. The *delegate* axis (person tags) is mutated only when the caller explicitly passes `personTagIds` — a Next/Someday/Trash route on a delegated task does not strip the delegate, so a task can be `waiting for trixy` *and* have a new next action like `call trixy for update` without losing the delegate when the user routes it. The *user-action* axis (`next_action_text`) is written by `applyRouting` only when the caller passes `nextActionText` (typically through the `nextActionDialog` modifier or a callsite-owned setter); plain Next / Waiting For routes from `ProcessToHandlers` do not synthesise a phrase.

**Cleanup invariant on `done_at`:** any non-Done, non-Trash route clears `done_at` if set, so promoting a previously-completed task back to active state can't leave a stale completion timestamp. `Done` refreshes the timestamp; `Trash` leaves it alone so the completion record survives a soft-delete.

**Restore routes through the same matrix:** the task-detail status sheet restores a trashed Outcome via "Restore to Next" / "Restore to Someday/Maybe", and a done-only Outcome via a single "Restore" (to Next); all three tiles call `TaskDetailNotifier.restoreTo(RoutingKind)` → `applyRouting`. There is no bespoke restore DAO method — the forward matrix already sets the chosen intent, clears `done_at` (cleanup invariant; required so a completed-then-trashed Outcome re-projects onto Next / Someday-Maybe rather than Done), stamps `last_clarified_at`, and leaves person tags alone (orthogonality invariant), so a delegated Outcome restored to Next correctly resurfaces on Waiting For too.

**Provenance — "Captured from…" (issue #184 Phase 4):** `TaskDetailScreen` renders a collapsed section listing the Captures an Outcome was clarified from — each source Capture's raw fragment and when it was captured — driven by `capturesForOutcomeProvider` (`CaptureDao.watchCapturesForOutcome`, the `capture_outcomes` join). The section is hidden entirely when the Outcome has no links, so historical Outcomes (created before the split, or outside the clarify flow) show nothing and no threshold logic is needed. Links are written by `ClarificationService.clarifyCaptureToOutcome`, so every Capture clarified since the cutover carries one; Outcomes that predate it show nothing.

**Live-refresh invariant (view writes must self-notify):** in production `todos` / `tags` / `todo_tags` are PowerSync views with `INSTEAD OF` triggers, so a Drift `UpdateStatement.write` / `DeleteStatement.go` against them reports `changes() == 0` and Drift skips its built-in stream invalidation (which is gated on `rows > 0`). That leaves the async `SqliteAsyncDriftConnection` bridge — `PowerSyncDatabase.updates` → `handleTableUpdates` — as the *only* thing that refreshes view-backed watchers, and that bridge can be briefly silent on a cold start. Every `TodoDao` / `InboxDao` method that writes the `todos` view directly therefore calls `GtdDatabase.notifyTodosViewWrite(...)` immediately after the write (`applyRouting`, `setNextActionText`, `rescheduleTask`, `stampLastClarifiedAt`, `setPersonTagsAndStamp`, `clearDoneAt`, `updateFields`, `InboxDao.processInboxItem`, and the `delete`-based `InboxDao.deleteTodo`) to give Drift a second, in-process invalidation path; the Inbox list, Inbox badge, and Next Actions list refresh without an app restart. The helper emits kind-less `TableUpdate`s, so a single call serves updates and deletes alike. Only `update` / `delete` need it: `into(todos).insert(...)` and `customUpdate` / `customInsert` notify unconditionally, so captures and DAO methods built on them (`markDone`, `setIntent`, …) already satisfy the invariant. Any new method that writes a view directly with `update`/`delete` must add the same call.

### `ProcessToHandlers` — the canonical "process to" action bar

`ProcessToHandlers` (`app/lib/widgets/process_to_handlers.dart`) is the single widget rendered wherever the user commits a routing verdict — against either shape of the ADR-0006 split, an Outcome (`OutcomeSubject`) or a Capture (`CaptureSubject`). Its surfaces: the standalone `InboxClarifyScreen`, the inbox-clarify card (planning Step 0 and weekly review's zero-inbox step), the daily planning task-review step, and the weekly review's Waiting For / Next Actions / Someday-Maybe steps.

The widget owns its writes, delegated to `ClarificationService`. Callsites speak `ProcessAction` (`keep`, `reclarify`, `next`, `waitingFor`, `someday`, `done`, `trash`, plus the `nextActionDialog` modifier on `next`) and never see `RoutingKind`. Callsites that hold a `RoutingKind` from a session record translate at the read site via the co-located `RoutingKind.toProcessAction()` extension. `keep` and `reclarify` have no `RoutingKind` equivalent (`keep` stamps `last_clarified_at` only; `reclarify` opens a sub-flow whose result bubbles back as the chosen routing action).

The `nextActionDialog` modifier is **on by default** — promoting a Todo to Next always opens `NextActionDialog` to capture a phrase, so a freshly-promoted task lands on the Next list with a defined action rather than re-surfacing in the daily re-clarification queue. The inbox-clarify card opts out via `except: {nextActionDialog}` because it supplies the phrase through the title-as-action coupling instead; the Next Actions weekly-review step also excepts it (it has no Next button at all).

API:

- `include: Set<ProcessAction>` — surface non-default actions (e.g. `keep`). The `nextActionDialog` modifier is default-on, so it is removed via `except`, not added via `include`.
- `except: Set<ProcessAction>` — hide default actions and the default-on `nextActionDialog` modifier (e.g. the Waiting For step uses `except: {waitingFor}` because the user is already on a waiting item, Keep covers re-confirmation; inbox-clarify uses `except: {nextActionDialog}` to keep Next as a one-tap route).
- `disabled: Set<ProcessAction>` — render disabled-state but still draw the button (parent-owned validation, e.g. inbox card disables routes while the title is empty).
- `labels: Map<ProcessAction, String>` — per-callsite label overrides, applied over the subject-resolved defaults. Use sparingly: the defaults are the canonical vocabulary and the widget exists to collapse the pre-extraction drift.

Labels are resolved from the subject, not fixed per action. `trash` is the one action whose canonical name differs by shape: on an `OutcomeSubject` it is **Trash** (`Intent = trash`, landing the row on the Trash List), on a `CaptureSubject` it is **Discard** — the zero-Outcome verdict creates nothing, so the item never reaches that List and "Trash" would name a destination it never arrives at. Because the resolution lives in the widget, the copy cannot drift between clarify surfaces.

The widget owns the tap handler, so no callsite can catch failures itself — it therefore reports them, behind **two separate error boundaries**:

- A **routing write** that throws is caught and reported as "Operation failed. Please try again."; `onAfterRoute` is not called, so a failed write never advances a cursor or records a routing.
- A throwing **`onAfterRoute` hook** is caught separately and reported as "Saved, but finishing up failed…". The write has already landed by then, so reusing the retry copy would invite the user to redo a route that actually succeeded.
- `lastAction: ProcessAction?` — drives the "previously selected" affordance on the matching button when the user backs up to revisit an item.
- `onAfterRoute: (ProcessAction) -> Future<void>` — fires once after the action settles without error (after `keep` stamps `last_clarified_at`, and after a route commits). Used for callsite-specific bookkeeping (advancing a snapshot cursor, recording the routing for the highlight) and for callsite-owned writes on the user-action axis — e.g. `ClarifyCard` mirrors the live title into `next_action_text` here when the user routes to Next/Waiting For from a clarify card (title-as-action coupling). Not called when the user cancels a sub-dialog, and not called when the write throws.

  It does **not** imply a persisted route in every case: saving the `nextActionDialog` with an empty phrase deliberately skips the write (promoting to Next with no phrase would land the item actionless) yet still fires the hook, so the callsite can react — its handler re-reads the row and sees the unchanged value. Handlers must therefore read state rather than assume a write landed.
- `onProcessingChanged: (bool) -> void` — mirrors the bar's in-flight state out to the callsite, for surfaces that render their own affordances beside it. `InboxClarifyScreen` uses it to disable its Skip button during a write, so the user cannot pop the screen before the post-route text flush runs.

Sub-flows owned by the widget:
- The Waiting For button opens `PersonTagPickerSheet`, which **pops with the chosen person-tag ids** (`null` on cancel) rather than writing them itself. The widget awaits that result and, only once the sheet has closed and the subject is confirmed to still exist, commits intent + delegate in a single routing write — `clarifyToOutcome` replaces the person-tag set atomically on an Outcome, `clarifyCaptureToOutcome` attaches it to the Outcome it mints. Cancelling writes nothing and fires no hook. `next_action_text` is on the orthogonal user-action axis and is left alone.
- The `nextActionDialog` modifier opens `NextActionDialog` (`app/lib/widgets/next_action_dialog.dart`) prefilled with the existing `next_action_text` and writes the new phrase on save — this is the only widget-internal path that mutates the user-action axis. Because the modifier is default-on, this is the standard Next behaviour everywhere except the callsites that `except` it. The weekly review's Waiting For and Someday/Maybe steps rely on it so a promotion to Next captures a phrase; their `onAfterRoute` reads the phrase back and, if the user saved it blank, stays on the item rather than advancing an actionless task onto the Next list. Promoting a delegated Waiting For item to Next keeps its person tags (intent ⊥ delegate) — `applyRouting` only touches the delegate axis when `personTagIds` is passed.
- The `Re-clarify…` button (surfaced by adding `reclarify` to `include`) pushes a full-page `ClarifyCard.forOutcome` route. Routing inside the sub-flow is committed by the inner card's own `ProcessToHandlers`; the result is popped back to the outer widget which bubbles it through `onAfterRoute` for callsite bookkeeping (record routing, advance cursor) — the outer widget never re-writes the route. Backing out of the sub-flow without routing returns no result and is bubbled as `keep`, so the review step advances without recording a routing while keeping any field edits the user already autosaved.

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

**Disjointness invariant:** each task surfaces in at most one wizard step. The selectors are pairwise disjoint by construction — Inbox vs everything is split by table (Captures vs Outcomes); Waiting For vs Someday and Next Actions vs Someday split on `intent`; Waiting For vs Next Actions split on whether the task carries any person-typed tag (`getNextExcludingPersonTagged` enforces the exclusion in SQL). A future dedicated Projects step will need to re-establish this matrix (project-tagged ⊂ next-actions, so it would have to be ordered ahead of Next Actions or the Next Actions snapshot would have to also exclude project-tagged items).

**Snapshot loaders** are called by `_onStepEnter` each time a step is entered. All four snapshots are also pre-loaded in `loadAllSnapshots()` which runs on ceremony mount, so items routed in an earlier step do not surface in a later one. Empty steps show an empty-state view inline; the user clicks Next to advance rather than being auto-skipped past the step.

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
| `periodic_review_nudge_content_firing_edge` | ISO-8601 datetime | Most recent content-state `false→true` firing edge; a content-state dismiss releases once `dismissed_at` precedes it |

Derived providers: `periodicReviewIsDueProvider`, `periodicReviewBannerDismissedTodayProvider`, `periodicReviewBannerEnabledProvider`, `periodicReviewLastCompletedProvider`.

### UI

- `screens/periodic_review/periodic_review_screen.dart` composes four list-driven steps against the shared `Wizard` widget; the "Review Complete" summary screen is rendered standalone once `currentStep` is past the last list-driven step, not as a wizard step. Step transitions go through `advanceStep` / `goToStep`, which fire the entry hook for snapshot loading.
- Each list-driven step's footer is a `ListItemFooter` widget owned by the step (shipped alongside `Wizard` in `app/lib/widgets/ceremony/wizard.dart`). Skip advances the per-item cursor (`advanceInbox` / `advanceWaitingFor` / …) while items remain — including on the last real item; Next step crosses into the following wizard step only after the cursor has advanced past the last item (`nav.isComplete`) and the step body shows its completion placeholder. Back symmetrically retreats the cursor before crossing back; from item 0 of any non-first list-driven step it falls through to `goToStep(currentStep - 1)`. Empty steps show an empty-state view inline; the user clicks Next to advance rather than being auto-skipped past the step.
- Per-item steps (Waiting For, Next Actions, Someday/Maybe) share `_review_card.dart` (`ReviewItemCard`, `ReviewLoadError`, `ReviewEmptyState`). Each per-item step inlines its load-error/loading/empty/completion branching directly in its `build` method (`ReviewLoadError` → spinner → `ReviewEmptyState` → `ReviewItemCard`). Each per-item step's `ProcessToHandlers` includes `ProcessAction.reclarify`, surfacing a `Re-clarify…` button that opens the full `ClarifyCard` UI as a sub-flow; routing inside the sub-flow is recorded and advances the cursor exactly like a direct tap, while backing out without routing maps to `keep` (advance without recording).
- Step 0 (Process Inbox) uses `ClarifyStep` (`app/lib/widgets/ceremony/clarify_step.dart`) — the same class as DPR's inbox step; it passes WR-specific nav, routings, and callbacks as constructor arguments. The completion frame is the canonical `_InboxCleared` widget shared with DPR.
- `widgets/periodic_review_banner.dart` — teal banner above app-shell views. Banner toggle must be enabled, the user must have at least one todo, and dismissed-today must be false. Given those, it shows when **either** the review is due per the 7-day cadence, **or** the inbox and next-actions are both empty while waiting-for or someday/maybe still holds items. The second trigger fills the gap left by `FocusSessionPlanningBanner` (which suppresses itself in that state per #258) so the user is nudged toward the weekly review when there is nothing to plan today but deferred inventory remains. Both branches read the unfiltered list providers (`unfilteredInboxProvider`, `unfilteredNextActionsProvider`, `unfilteredWaitingForProvider`, `unfilteredMaybeProvider`) so an active context-tag filter does not change visibility.

### Notifications

`NotificationService.schedulePeriodicReviewReminder(time:)` schedules a recurring daily reminder at the configured time using `matchDateTimeComponents: time`. `_rescheduleNotification` only arms that schedule while the review is actually due (`periodicReviewIsDueProvider == true`); on completion the reschedule is triggered by the prefs listener and the schedule is canceled, so the user is not nagged daily until the cadence has elapsed again. Re-arm happens via the same listener on the next prefs write (or via `build()` the next time the notifier is constructed at app launch).

### Trigger reactivity

Nudge Triggers re-evaluate when their predicate's inputs change, not only on an unrelated rebuild, so a Nudge surfaces at its boundary or content edge rather than waiting. Time-based predicates read the shared `clockProvider` (`lib/providers/clock_provider.dart`) and arm timers to their next boundary: the Nudge module's `nudgeBoundaryTickProvider` schedules one timer to the next day-rollover / Evening Shutdown anchor and re-evaluates the Triggers there, while `periodicReviewIsDueProvider` schedules its own timer to the cadence-due instant (`last + 7d`); both cancel via `ref.onDispose`.

The Weekly Review's **content-state Trigger** (inbox and next-actions empty while waiting-for or someday/maybe still holds items) tracks its own firing edge, so a dismiss releases on the next genuine `false→true` content transition rather than at the day boundary. `wrContentFiringProvider` exposes the predicate as a tri-state `bool?` (`null` while the underlying lists load, then `false` / `true`); `contentFiringEdgeProvider` (a `Notifier<DateTime?>`) watches it and, on a `false→true` transition, stamps `clockProvider()` as the new edge and persists it to `periodic_review_nudge_content_firing_edge`. On startup the transition is `null→true`, so it instead restores the persisted edge — or falls back to start-of-today when nothing is persisted — and a cold start mid-firing therefore does not reset an outstanding dismiss. The Nudge dismiss predicate releases when `dismissed_at` precedes the edge (see `CONTEXT.md` → Nudge).

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
| Clarified | `todos.clarified` (bool) | Legacy of the Capture/Outcome conflation. No longer read — the Inbox is `captures.clarified_at IS NULL` — but still written when an Outcome is created. Dropped a release train after #184. |
| Intent | `todos.intent` (`next` \| `maybe` \| `trash`) | What the user wants to do with this task |
| Completion | `todos.done_at` (timestamp, nullable) | Non-null = done; value = when |
| Schedule | `todos.due_date` (date, nullable) | Specific calendar date |
| Current Action | `todos.next_action_text` (text, nullable) | The Outcome's current Action phrase; non-null/non-blank = actionable today |
| PersonBlocker | `todo_tags` rows referencing a `Tag` with `type = 'person'` | Outcome is blocked on a Person; existence of the link is the block, removal is its resolution |
| Active focus | `focus_sessions.current_task_id` | Which task is currently in progress |
| Today's plan | `focus_session_tasks` rows | Membership in the open session |

A task is **actionable** when:

```text
clarified = true ∧ done_at IS NULL ∧ intent = 'next'
```

PersonBlocker is the only Blocker shape modelled today; the remaining shapes from the polymorphic-blockers design (Task / Time / Location) are tracked in TMaYaD/Jeeves#181 and are not part of this model yet.

### Next List

The Next List rule is:

```text
Next = intent='next' ∧ clarified ∧ done_at IS NULL ∧
       (next_action_text IS NOT NULL ∨ no PersonBlocker on the Outcome)
```

`TodoDao.watchNext(tagIds:)` enforces it. The single excluded quadrant is **actionless** (`next_action_text` null or whitespace) **AND** PersonBlocked (carries any `Tag(type='person')`) — that combination is a pure wait and surfaces only on Waiting For. An Outcome with a current Action belongs on Next regardless of any PersonBlocker: `"call Trixy for a follow up"` is doable and eligible for engagement; it also surfaces under Waiting For (the grouping by Person). The overlap between Next and Waiting For is by design — see CONTEXT.md § Next / Waiting For.

The exclusion clause in SQL:

```sql
AND (
  (todos.next_action_text IS NOT NULL AND TRIM(todos.next_action_text) != '')
  OR NOT EXISTS (
    SELECT 1 FROM todo_tags tt
    JOIN tags tg ON tg.id = tt.tag_id
    WHERE tt.todo_id = todos.id AND tg.type = 'person'
  )
)
```

The clause applies under context-tag filtering too — the actionable+PersonBlocked overlap stays on filtered Next, the actionless+PersonBlocked Outcome never leaks in.

The Weekly Review wizard's Next-step snapshot (`TodoDao.getNextExcludingPersonTagged`) and the daily re-clarification's "actionless" branch (`TodoDao.watchNeedsReview`) apply a stricter per-step person-tag exclusion to keep their own wizard steps disjoint from Waiting For's step. Those are wizard-internal disjointness rules, not the everyday Next List membership rule.

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

**Waiting For overlaps with Next when the Outcome has a current Action.** An Outcome with `intent='next'`, a non-null `next_action_text`, and at least one `Tag(type='person')` appears on both lists — Next because the Action is doable (`"call Trixy for a follow up"`), Waiting For because the PersonBlocker is real. An *actionless* PersonBlocked Outcome appears on Waiting For only — the Next predicate (above) excludes that single quadrant.

### Intent semantics

- `next` — normal actionable item; appears on Next (subject to the actionless+PersonBlocked exclusion above) and **also** under Waiting For (grouped by Person) when the Outcome carries any `Tag(type='person')`. The two views overlap by design when both predicates apply.
- `maybe` — deferred for later consideration; surfaces in the Maybe view; excluded from Next Actions and planning reviews.
- `trash` — discarded (soft delete; column domain enforced at DB level). Surfaces on the Trash record screen (see "Record surfaces" under Navigation); restorable to Next or Someday/Maybe from the task-detail status sheet. Rows are never physically deleted.

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

### Record surfaces (Done / Trash)

`/done` and `/trash` are `ShellRoute` children rendering thin `GtdListScreen` wrappers (`DoneScreen`, `TrashScreen`) over the unfiltered `doneProvider` / `trashProvider` streams (`TodoDao.watchDone()` / `watchTrash()`). They are reached from a de-emphasised record group at the bottom of the drawer's scrollable nav column, above the fixed Settings tile — muted styling, no count badges (record size is not actionable signal). Trash lists every `intent='trash'` row regardless of `done_at`, newest-trashed first (`ORDER BY COALESCE(last_clarified_at, updated_at, created_at) DESC` — every trashing write path stamps `last_clarified_at`, so the stamp proxies a dedicated `trashed_at` column; the fallbacks cover legacy rows predating it). Done excludes trashed rows (#278), keeping the two surfaces disjoint. Rows navigate to `/task/:id`; restore lives in the task-detail status sheet (see "Routing transitions"). There is deliberately no purge action — rows are never physically deleted.

### Tag Cloud Navigation Filter

A sticky, multi-select context-tag filter lives in the navigation drawer and persists across screen navigation for the duration of the app session.

**State:** `TagFilterNotifier` (a `Notifier<Set<String>>` in `app/lib/providers/tag_filter_provider.dart`) holds the active set of context tag IDs.  Calling `toggle(id)` adds or removes a tag; `clear()` resets the set.  The `tagFilterProvider` is app-scoped so the state survives route changes.

**Drawer widget:** `TagCloud` (`app/lib/screens/common/tag_cloud.dart`) renders a `Wrap` of `FilterChip`s sourced from `contextTagsWithCountProvider`.  Chip visual weight (font size and opacity) scales linearly with each tag's active-task count relative to the maximum in the set.  Tags with zero active tasks are hidden unless currently selected.  Long-pressing a chip opens `TagManagementSheet` for rename/recolour/merge.

**Active filter indicator:** `_ActiveFilterBar` (embedded in `GtdListScreen`) and `_InboxFilterBar` (embedded in `InboxScreen`) show the currently selected tags as removable `InputChip`s plus a "Clear all" button.  The CONTEXTS section header in the drawer gains a count badge when any filter is active.  `GtdListScreen` takes `showFilterBar: false` for the Done and Trash record surfaces, whose streams deliberately ignore the context-tag filter — rendering a filter bar the list doesn't apply would lie to the user.

**DAO layer:** `TagDao.watchTagsWithActiveCount(userId, type)` uses a `customSelect` SQL query with `readsFrom: {tags, todoTags, todos}` so the count stream re-emits reactively when any of the three tables change.  Each GTD watch method in `TodoDao` and `InboxDao` accepts an optional `Set<String> tagIds` parameter; when non-empty a SQL subquery enforces AND semantics: `COUNT(DISTINCT tag_id) WHERE tag_id IN (...) = N`.

**Provider wiring:** Every GTD list provider (`nextActionsProvider`, `waitingForProvider`, `maybeProvider`, `inboxItemsProvider`) watches `tagFilterProvider` and passes the current tag set to its DAO method.  When the filter changes, Riverpod automatically cancels and re-subscribes the DAO stream, so the list view re-renders without any additional work in the UI layer.
