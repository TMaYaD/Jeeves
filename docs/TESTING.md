# Testing Strategy

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

This document outlines the testing methodology and standards for the Jeeves project.

## Development Methodology: TDD (Top-Down)

We follow a strict Test-Driven Development (TDD) cycle in a Top-Down approach. The fundamental step before adding any new feature is to define its expected behavior via a failing test.

### Testing Hierarchy

1. **Write E2E Tests First**
   Start with end-to-end (E2E) tests that verify complete user journeys. E2E tests validate that all pieces of the system work together from the user's perspective.
   - *Workflow:* Write test that exercises the full user flow → Test fails → Implement.

2. **Write Integration Tests Second**
   Test component interactions at the boundaries (e.g., API boundaries, database access boundaries).

3. **Write Unit Tests Third**
   Test pure business logic, utilities, and parsers in complete isolation.

### Implementation Workflow

1. Write a failing test defining the expected behavior.
2. Implement minimum code to make the test pass.
3. Refactor and ensure the tests remain green.
4. Check for regressions by running the full test suite.

## Core Testing Principles

- **Test Real Behavior Only**: Avoid mocking system components whenever possible. Test code as it would run in production. If a component is too complex to test without excessive mocking, it should be redesigned.
- **Automation First**: Linter, analyzer, and the full test suite must pass locally before any commits are pushed.
- **No Unverified Work**: Code is considered incomplete until it has corresponding automated tests demonstrating its correctness.

## Stack-Specific Testing

### Frontend (Flutter)

- **Framework**: `flutter_test`.
- **E2E/Integration**: Flutter Integration Tests for on-device testing.
- **Unit/Widget**: Widget tests and standard Dart unit tests for Riverpod providers and logic.
- **Never assert on affected-row counts** (`changes()`, the value Drift returns from `update`/`delete`) for writes to `todos` / `tags` / `todo_tags`. In production these are PowerSync views with `INSTEAD OF` triggers, so the count is always 0 — such an assert passes under the `NativeDatabase.memory()` test harness (real tables) and throws only in production. Rely on the WHERE-clause optimistic lock instead. See the live-refresh invariant in [ARCHITECTURE.md](./ARCHITECTURE.md) for the same mechanism's effect on stream invalidation.
- **Pre-commit hook fails with "Flutter SDK version is 0.0.0-unknown"**: git exports `GIT_DIR`/`GIT_INDEX_FILE` into hooks, which poisons the shared `/opt/flutter` SDK's version computation — its staleness check runs git against the *project* repo and rewrites `bin/cache/flutter.version.json` as `0.0.0-unknown`, after which `dart pub` fails version solving. Retrying can never work while the hook re-poisons the file. Fix per worktree: `rm -rf app/.fvm/flutter_sdk && mkdir -p app/.fvm && cp -a /opt/flutter app/.fvm/flutter_sdk` (untracked, gitignored via `.fvm/`), then insert `unset "${!GIT_@}"` after the shebang of its `bin/flutter` and `bin/dart`. The `mkdir -p` is required on a fresh worktree, which has no `app/.fvm`, and the `rm -rf` on one already initialised — `cp -a src dst` copies *into* an existing `dst`, silently producing `app/.fvm/flutter_sdk/flutter` instead of replacing it. The copy is a derived cache, so discarding it is safe. The hook prefers `.fvm/flutter_sdk/bin` over the system SDK. Heal an already-poisoned shared SDK by deleting `bin/cache/flutter.version.json` and running `flutter --version` outside a hook (with `GIT_*` unset), then confirm `frameworkVersion` matches `.fvmrc` and `repositoryUrl` is not this repo.

  A *thin shim* that unsets `GIT_*` and `exec`s `/opt/flutter/bin` is not sufficient when several worktrees share one SDK: the shim still reads the shared `bin/cache/flutter.version.json`, so a sibling worker's unshimmed hook can poison that file in the window between this hook's `flutter --version` self-heal and its `dart run build_runner`. `dart pub` only reads the file — it never recomputes it — so the commit fails even though the shim did its job. Copying the SDK gives the worktree its own cache and closes the race; the cost is ~1.5 GB per worktree.

### Backend (FastAPI)

- **Framework**: `pytest` running with `pytest-asyncio` for asynchronous tests.
- **Coverage**: `pytest-cov` to ensure critical business logic is tested.
- **Local DB**: Provide a test database (e.g., using `aiosqlite` or a testing PostgreSQL container) to run real integration tests rather than mocking the database layer.

## Sync conflict resolution (manual)

The per-key conflict logic in `services/user_preferences_conflict.dart` is a pure function and is fully covered by `app/test/services/user_preferences_conflict_test.dart`. What that layer **cannot** cover is the PowerSync engine's delete-on-server-absent behaviour: the entire Dart test harness runs on `NativeDatabase.memory()` — a real SQLite table with no PowerSync engine — so the download-reconciliation windows in [SYNC.md](./SYNC.md#powersync-reconciliation-behaviour-write-checkpoint) are structurally unreproducible in unit tests. A standing PowerSync-client + docker-compose integration harness is deferred to its own infra issue.

Until that harness exists, verify these acceptance criteria manually against a real backend (two emulators/devices, or one device plus a direct DB edit):

- **Server-absent row survives (offline write).** On device A, toggle a preference (e.g. change the daily-planning time) while the backend is unreachable, then reconnect against a server that has **no** row for that key. Confirm the local value persists — including across a cold restart of the app (which rebuilds `syncedPreferencesProvider` from the DB, bypassing the in-memory merge performed after `dao.watchAll(userId)` emits). Assert on `dao.getAll(userId)` / the DB row, not on notifier state, because the in-memory merge can mask a wiped DB row.
- **Both present, LWW keys: newer `updated_at` wins.** Write the same scalar key on two devices; confirm the later write is the value both devices settle on.
- **Snooze floors never regress (`maxTimestampValue`).** Snooze a notification further into the future on device A, then let an older write carrying a nearer snooze value sync from device B; confirm the later "until" survives and the notification stays silenced. Confirm an explicit un-snooze (tombstone) clears the floor even against a live value.
- **Set/list keys merge (`setMerge`).** No production key uses this today; when one is added, add two concurrent additions on two devices and confirm both survive.

## Manual testing on the Android emulator (for agents)

For flows that are impractical to cover with `flutter_test` / integration tests — in particular the Sign-In With Solana round-trip, which requires a real MWA-compatible wallet — drive the running emulator via `adb`. This section captures the stable coordinates and navigation paths so successive sessions don't have to re-discover them.

### Device & app context

- Emulator physical size: **1080x2400** (`adb shell wm size` to confirm). All coordinates below assume this; if the device is different, scale proportionally.
- Jeeves package (dev flavor debug): `loonyb.in.jeeves.dev`
- Mock MWA Wallet: `com.solana.mwallet`, PIN **1234** (the "Mock" is the wallet — the app itself must NOT be mocked).
- Compose stack: `podman compose -f infra/docker-compose.yml up -d` (backend reachable from emulator at `http://10.0.2.2:8000`).
- SWS build command:
  ```
  flutter build apk --flavor dev --debug \
    --dart-define=JEEVES_AUTH_MODE=sws \
    --dart-define=JEEVES_API_URL=http://10.0.2.2:8000
  ```

### How to drive `adb` efficiently

- **Chain taps, don't screenshot between every step.** Each `screencap` + `pull` is ~1–2s of overhead; chain the full navigation in one Bash call, then screenshot only at the verification point. Example — sign-out from inbox:
  ```
  adb shell input tap 106 170    # open drawer
  sleep 1.5
  adb shell input tap 250 2280   # Settings
  sleep 1.2
  adb shell input tap 540 552    # Sign out tile
  sleep 1
  adb shell input tap 844 1378   # confirm
  sleep 2
  adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png /tmp/s.png
  ```
- Use `adb shell monkey -p loonyb.in.jeeves.dev -c android.intent.category.LAUNCHER 1` to cold-launch; prefix with `adb shell am force-stop loonyb.in.jeeves.dev` for a clean start.
- Stream Flutter errors: `adb logcat > /tmp/jeeves.log &` then grep for `flutter:` and `AndroidRuntime`. MWA failures surface as `com.solana.mobilewalletadapter.clientlib.*` stacks.

### Inspecting the on-device database

When the UI and the user's intent disagree, query the on-device database directly before reading provider/widget code — it splits persistence bugs from watcher/stream bugs in one step. Works on debug builds via `run-as`:

```
adb exec-out run-as loonyb.in.jeeves.dev cat app_flutter/jeeves.sqlite     > /tmp/jeeves.sqlite
adb exec-out run-as loonyb.in.jeeves.dev cat app_flutter/jeeves.sqlite-wal > /tmp/jeeves.sqlite-wal
adb exec-out run-as loonyb.in.jeeves.dev cat app_flutter/jeeves.sqlite-shm > /tmp/jeeves.sqlite-shm
sqlite3 /tmp/jeeves.sqlite "SELECT id, title, clarified, intent FROM ps_data__todos LIMIT 20"
```

Pull all three files — the WAL usually holds the most recent writes. Query the PowerSync backing tables (`ps_data__todos` etc.), not the `todos` view, which only exists while the app's PowerSync schema is attached. If the row is correct in SQLite, the bug is in watcher invalidation (see the live-refresh invariant in [ARCHITECTURE.md](./ARCHITECTURE.md)); if it's wrong, the bug is in the write path.

### Navigation tree with tap coordinates

Coordinates are `(x, y)` in device pixels. The drawer lives under a hamburger icon on every main shell route.

| Location | Coords | Notes |
|---|---|---|
| **App shell (Inbox etc.)** → hamburger / drawer | `(105, 423)` | Top-left button below the large title header; bounds `[42,360][168,486]`. |
| **Drawer** → Settings row | `(250, 2280)` | Near bottom of drawer; wait ~1s after opening. |
| **Settings** → back arrow | `(106, 170)` | Top-left `BackButton`. |
| **Settings (signed-in)** → Sign out tile | `(540, 552)` | Second tile under SYNC. |
| **Settings (signed-out)** → "Sign in to sync across devices" tile | `(540, 440)` | First tile under SYNC. |
| **Sign-out confirm dialog** → red "Sign out" | `(844, 1378)` | Right-side action. |
| **Sign-out confirm dialog** → "Cancel" | `(284, 1378)` | Left-side action. |
| **Login screen** → "Connect wallet" button | `(540, 1416)` | Center. In SWS mode this is the only action. |
| **Login screen (canPop=true)** → close (X) | `(88, 140)` | Only present when reached via push (e.g. from Settings). |
| **Notification permission dialog** → "Don't allow" | `(540, 1452)` | First-launch prompt. |
| **Mock MWA Wallet — connect prompt** → "Connect" | `(810, 2200)` | Green button, bottom-right. |
| **Mock MWA Wallet — SIWS sign message** → "Approve" | `(800, 2160)` | Green button, bottom-right. |

### Reference flows

**First-launch SWS sign-in** (assumes Mock MWA Wallet already installed):
1. Dismiss notification permission: `tap 540 1452`
2. Connect wallet: `tap 540 1416`, wait ~2s for wallet UI
3. Wallet "Connect": `tap 810 2200`, wait ~2–3s for SIWS dialog
4. Wallet "Approve": `tap 800 2160`, wait ~3s
5. Verify: `/inbox` visible with "What's on your mind?"; `POST /auth/sws/challenge` and `POST /auth/sws` both 200 in backend logs; row in `users` with `solana_public_key` populated.

**Sign-out from Settings** (should stay on Settings in its signed-out state):
1. From `/inbox`: `tap 106 170` → `tap 250 2280` → `/settings`
2. `tap 540 552` (Sign out tile) → dialog
3. `tap 844 1378` (red confirm)
4. Verify: still on `/settings`, SYNC section now shows "Sign in to sync across devices" tile (not "Sync enabled" + "Sign out").
