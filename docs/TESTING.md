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
- **Tests verify behaviour, not styling choices.** Never assert on visual styling — corner radii, colors, fonts, sizes, spacing, or exact copy. A styling assert either restates a shared design token (proves nothing) or hardcodes a value that fires on every deliberate design tweak (a change-detector, not a guard). Design decisions live in `docs/DESIGN.md` and are enforced by construction — shared widgets and tokens — not by tests. Asserting on a widget's *presence*, *state*, or *wiring* is behaviour; asserting on how it is painted is not.
- **Automation First**: Linter, analyzer, and the full test suite must pass locally before any commits are pushed.
- **No Unverified Work**: Code is considered incomplete until it has corresponding automated tests demonstrating its correctness.

## Stack-Specific Testing

### Frontend (Flutter)

- **Framework**: `flutter_test`.
- **E2E/Integration**: Flutter Integration Tests for on-device testing.
- **Unit/Widget**: Widget tests and standard Dart unit tests for Riverpod providers and logic.
- **Never assert on affected-row counts** (`changes()`, the value Drift returns from `update`/`delete`) for writes to `todos` / `tags` / `todo_tags`. In production these are PowerSync views with `INSTEAD OF` triggers, so the count is always 0 — such an assert passes under the `NativeDatabase.memory()` test harness (real tables) and throws only in production. Rely on the WHERE-clause optimistic lock instead. See the live-refresh invariant in [ARCHITECTURE.md](./ARCHITECTURE.md) for the same mechanism's effect on stream invalidation.
- **A live Drift `watch()` reached from a widget test hangs the run.** Drift's `StreamQueryStore` keeps a pending timer alive, and the test binding owns the clock, so `pumpAndSettle` never settles: it spins until its 10-minute default timeout, which looks like an infinite hang rather than a failure. Two shapes to avoid:
  - *Awaiting a stream directly* (`await db.captureDao.watchInbox().first`) — the first event is never delivered and the isolate blocks so hard the per-test timeout can't fire. Read with a plain `select` instead.
  - *A widget under test subscribing to one* (a `StreamProvider` backed by `query.watch()`). Either override the provider with `Stream.value(...)` in the harness — what `clarify_card_test.dart` and `process_to_handlers_test.dart` do — or, if the surface never renders the data live, have it do a one-shot read instead of a watch. `ClarifyCard` selects between the two with `ClarifyTagSection`: `draftInputOnly` renders no tag chips and reads the hints once via `CaptureDao.tagHintsForCapture`, so `clarify_surface_parity_test.dart` deliberately leaves `captureTagHintsProvider` un-overridden — if that option ever starts watching, the file hangs instead of passing quietly.
- **In an adopter's test, never `find.byKey` an `AppTitleBar` action directly.** Where a bar action renders depends on the width breakpoint (see DESIGN.md § App title bar): the same action sits in the bar on a wide surface and inside the ⋮ menu on a narrow one, so a screen test that finds it directly passes or fails by accident of the test surface size. Adopter (screen) tests go through `findBarAction(tester, key)` / `tapBarAction(tester, key)` from `test/helpers/app_title_bar_test_helpers.dart`, which look in the bar first and open the ⋮ menu when the action is not there. The exception is a test that is *specifically* asserting in-bar placement — e.g. that an action was demoted to an in-bar icon rather than overflowed — which scopes its finder to the `AppTitleBar` (`find.descendant(of: find.byType(AppTitleBar), …)`) and pins a known surface width. The component's own tests (`app_title_bar_test.dart`), which drive the surface width themselves, may assert bar internals directly. The budget arithmetic itself (`actionBudget`, `splitActions`) is pure and unit-tested without pumping a widget.
- **Never wait for a real-async drift write with a fixed sleep.** An in-memory drift write completes on the real event loop in microseconds; a `runAsync(Future.delayed(...))` "settle" charges its full duration on every host and masks hangs. Use `settleWithRealAsync(tester)` from `test/helpers/settle.dart` (drains the real event queue via a bounded `runAsync(() => pumpEventQueue())`, then `pumpAndSettle`) — if a test ever needs more than one real-async turn, raise its `rounds` parameter rather than reinstating a sleep.
- **`tester.tap` on a `ListView` child below the fold silently does nothing.** A `ListView` builds children within its `cacheExtent` while they still sit below the viewport, so the widget is findable but a tap at its centre hit-tests empty space (only a "would not hit test" warning). Worse, a child *beyond* the cacheExtent is not built at all, so the finder returns nothing and `ensureVisible` throws `Bad state: No element`. Drag until the finder is non-empty, then `ensureVisible`, then tap — see `_scrollAndTap` in `inbox_clarify_screen_test.dart` / `clarify_card_test.dart`.
- **`tester.enterText` leaves the field focused, so a focus-loss save has not happened yet.** Surfaces that save text on focus loss — `TaskDetailScreen`, `ActiveFocusScreen`, `ClarifyCard.forOutcome` (ADR-0023) — write nothing while the user is still in the field. A test that types and immediately asserts on the row is reading the *pre-edit* value, and reads as a broken save rather than a missing trigger. Drop focus first (`FocusManager.instance.primaryFocus?.unfocus()`, then pump) — see `_loseFocus` in `clarify_card_test.dart`. Assert **before** unmounting, too: a dispose-time flush would otherwise make a working focus-loss save and a broken one indistinguishable.
- **A focused text field keeps its wizard page mounted, so "the step unmounted" assertions lie.** `EditableText` is an `AutomaticKeepAliveClientMixin` client and wants to be kept alive while it holds focus, so a `PageView` step whose field is still focused stays in the tree off-screen when the wizard advances. `find.byKey` skips off-screen widgets by default, so the step *looks* gone while its `State` — and its controllers — quietly survive: a test of anything that happens on unmount (the `ClarifyRetention` stash, a dispose-time flush) then passes with the production code deleted. Drop focus before crossing the boundary, and assert the teardown with `skipOffstage: false` — see the step-crossing retention test in `focus_session_planning_back_test.dart`.
- **`ref.read` of a provider the widget never watches returns its initial state, not the real one.** A `StreamProvider` read for the first time inside a button callback is still `AsyncLoading`, so `status.asData?.value` is null and a `?? 'unknown'` fallback fires on every run — the surface looks wired up and quietly records the wrong value. The subscription has to exist before the callback: `ref.watch` it in `build` and pass the resolved value into the handler. A test that overrides the provider with `Stream.value(...)` does *not* paper over this; it reproduces it exactly, which is how `converge_verify_screen_test.dart` caught it. Watching is necessary but not sufficient: read the value as `status.value`, because a provider rebuilt by one of *its* dependencies sits in `AsyncLoading` still carrying the last real value, and `asData` is null there too — reproduce that state by overriding the provider with a body that watches a throwaway provider, then invalidating it.
- **Restore `debugPrint` inside the test body, never in `addTearDown`.** To assert on what a widget logged you swap `debugPrint` for a collector, but it is a foundation debug variable and the harness runs `debugAssertAllFoundationVarsUnset` at the end of the *test body* — before any tear-down fires. Restoring via `addTearDown` therefore fails every time with "The value of a foundation debug variable was changed by the test", pointing at the test rather than at the restore. Wrap the logging window in `try`/`finally` and reassign the original there; see the refresh-error case in `async_subject_test.dart`.
- **A deeply-nested worktree path breaks `flutter test` before a single test runs.** The native-assets step relinks `libpowersync_core.dylib` with `install_name_tool`, which fails when the rewritten install name does not fit the dylib's existing header padding: `changing install names or rpaths can't be redone … larger updated load commands do not fit`. The dylib was built for a path under the repo root, so a worktree nested a few levels deeper than that overflows the padding. Deleting `app/build/native_assets` does not help — the next run rebuilds it at the same long path and fails identically.

  Two things make this expensive to diagnose. It reports as a *build* error, not a test failure, so the run produces no test counts at all; and piping the command through `tail` discards the non-zero exit status, so a run that executed zero tests reads as a pass. Create agent worktrees at a short path (`/tmp/<name>`), and capture exit codes explicitly (`cmd > log 2>&1; echo "exit=$?"`) rather than trusting a piped summary line.

- **Pre-commit hook fails with "Flutter SDK version is 0.0.0-unknown"**: git exports `GIT_DIR`/`GIT_INDEX_FILE` into hooks, which poisons the shared `/opt/flutter` SDK's version computation — its staleness check runs git against the *project* repo and rewrites `bin/cache/flutter.version.json` as `0.0.0-unknown`, after which `dart pub` fails version solving. Retrying can never work while the hook re-poisons the file. You can confirm the diagnosis by reading `frameworkRevision` in that file: if it matches a *Jeeves* commit rather than a Flutter one, the SDK computed its version from this repo.

  **Thin shims over the shared SDK are not enough.** A shim that `unset`s `GIT_*` and `exec`s `/opt/flutter/bin/flutter` protects only its own invocations; the SDK underneath is still shared, so any sibling worktree whose hook invokes `/opt/flutter` directly re-poisons the one `flutter.version.json` for everyone. With several workers running concurrently this reads as a random, unreproducible failure.

  Fix per worktree, with a full private copy rather than a shim:

  1. Heal the shared SDK: `env -u GIT_DIR -u GIT_INDEX_FILE /opt/flutter/bin/flutter --version` (must be outside a hook).
  2. `rm -rf app/.fvm/flutter_sdk && cp -a /opt/flutter app/.fvm/flutter_sdk` (~1.5 GB; gitignored via `.fvm/`). The `rm -rf` is not optional: `cp -a src dst` copies *into* `dst` when it already exists, so re-running without it buries a second SDK at `app/.fvm/flutter_sdk/flutter` and leaves the outer path looking correct but broken.
  3. Insert `unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR` after the shebang in both `app/.fvm/flutter_sdk/bin/flutter` and `.../bin/dart`.

  The hook's resolution loop prefers `.fvm/flutter_sdk/bin` over the system SDK, so it picks the copy up with no further wiring. Verify by exporting `GIT_DIR`/`GIT_INDEX_FILE` by hand and running the hook's own steps (`dart run build_runner build`, `flutter analyze`, `flutter test`) — that reproduces the hook environment without needing a commit to fail.

### Backend (FastAPI)

- **Framework**: `pytest` running with `pytest-asyncio` for asynchronous tests.
- **Coverage**: `pytest-cov` to ensure critical business logic is tested.
- **Local DB**: Provide a test database (e.g., using `aiosqlite` or a testing PostgreSQL container) to run real integration tests rather than mocking the database layer.
- **bcrypt work factor**: `hash_password` reads `settings.bcrypt_rounds` (production default 12). `tests/conftest.py` sets `BCRYPT_ROUNDS=4` so the suite's many `register()` calls don't dominate the run — the real hashing code path is still exercised, just at a lower cost factor.
- **Shared engine, per-test rollback**: the `engine` fixture is session-scoped (`StaticPool`, one shared in-memory SQLite; schema built once), and the `db` fixture isolates each test with an outer transaction rolled back afterward (`join_transaction_mode="create_savepoint"`, so route-level `commit()`s persist within a test but never leak across tests). This relies on the SQLAlchemy-documented pysqlite fix in `conftest.py` — disable the driver's autobegin and emit `BEGIN` from event listeners — without which SAVEPOINT/rollback silently no-ops and committed rows leak between tests. Isolation is transactional, not a fresh DB: if test parallelism (`pytest-xdist`) is ever introduced, the engine must become per-worker.

#### Migration tests: two layers, and why both are needed

Most migration tests (`test_actions_migration.py`, `test_cursor_drop_migration.py`, `test_migrations.py`, …) drive a single migration's `upgrade()` by hand against synthetic SQLite tables. They are fast and they pin semantics, but they are blind to everything that only exists in the production stack — Postgres' own type deduction, asyncpg's prepared statements, and `alembic upgrade` walking the revision graph in order.

`test_migration_chain_postgres.py` is the other layer: it runs the **real chain** with the real `alembic` entry point, in a subprocess, over asyncpg, against a scratch Postgres database it creates and drops. Crucially it **seeds representative rows** at the revision before a data backfill and only then continues to head.

That seeding is the whole point. An empty database is not a cheaper version of this test — for a backfill migration it exercises none of it: the loop body never runs, so its SQL is never even prepared. Migration 0028 shipped a statement Postgres rejects outright (`AmbiguousParameterError`, one parameter bound in two positions with conflicting deduced types) and failed five consecutive production deploys while both the synthetic-table tests and CI's `python -m app.migrate` smoke check stayed green — because CI's database had no rows.

The test skips when `DATABASE_URL` does not point at Postgres, so local SQLite-only runs are unaffected; when `CI` is set it **fails instead of skipping**, since a silently skipped chain test is exactly how the gap stayed invisible. In CI it runs inside the existing `test` job, whose Postgres service container is therefore load-bearing for pytest and not just for the migrate smoke check.

**When you write a migration that touches data, add its row shape to the seed set here.** A backfill with no representative row in this module is untested.

## Sync conflict resolution (manual)

The per-key conflict logic in `services/user_preferences_conflict.dart` is a pure function and is fully covered by `app/test/services/user_preferences_conflict_test.dart`. What that layer **cannot** cover is the PowerSync engine's delete-on-server-absent behaviour: the entire Dart test harness runs on `NativeDatabase.memory()` — a real SQLite table with no PowerSync engine — so the download-reconciliation windows in [SYNC.md](./SYNC.md#powersync-reconciliation-behaviour-write-checkpoint) are structurally unreproducible in unit tests. A standing PowerSync-client + docker-compose integration harness is deferred to its own infra issue.

Until that harness exists, verify these acceptance criteria manually against a real backend (two emulators/devices, or one device plus a direct DB edit):

- **Server-absent row survives (offline write).** On device A, toggle a preference (e.g. change the daily-planning time) while the backend is unreachable, then reconnect against a server that has **no** row for that key. Confirm the local value persists — including across a cold restart of the app (which rebuilds `syncedPreferencesProvider` from the DB, bypassing the in-memory merge performed after `dao.watchAll(userId)` emits). Assert on `dao.getAll(userId)` / the DB row, not on notifier state, because the in-memory merge can mask a wiped DB row.
- **Both present, LWW keys: newer `updated_at` wins.** Write the same scalar key on two devices; confirm the later write is the value both devices settle on.
- **Snooze floors never regress (`maxTimestampValue`).** Snooze a notification further into the future on device A, then let an older write carrying a nearer snooze value sync from device B; confirm the later "until" survives and the notification stays silenced. Confirm an explicit un-snooze (tombstone) clears the floor even against a live value.
- **Set/list keys merge (`setMerge`).** No production key uses this today; when one is added, add two concurrent additions on two devices and confirm both survive.

## The Minimal Sync Server harness (automated)

The manual checklist above exists because the PowerSync engine cannot run in a Dart test. The op-log stack (`app/lib/sync/`, `backend/app/sync/`) is built so that it can, and `app/test/sync/` is where that pays off — N simulated devices, each with **both** of its stores and its own keypair, on a shared manually advanced clock, against an in-process server double. It covers the op-log stack only; PowerSync's reconciliation windows are historical — the engine no longer connects (#591), so they describe the shape of rows a pre-flip device holds rather than behaviour a shipped device can enter, and the manual checklist above is kept for that reading.

A `SimDevice` is a whole device: a `SyncDatabase` (the convergence substrate), a `GtdDatabase` wired with the production `WorkspaceRoutingOpCapture` (so the real DAOs author real ops, and a DAO-path preference write routes into the preferences Workspace rather than the GTD one), and a `DomainProjector` feeding the domain store back from reduced state. It enrols at construction; `harness/stack_phone.dart` is the sibling for cases that need a device that is *not* yet enrolled, built over a real `SyncStack`. Two consequences worth knowing before writing a case:

- **Entity ids must be canonical lowercase UUIDs.** The payload codec rejects anything else rather than normalising it, and since #573 authoring runs that same codec: a fixture id like `'outcome-1'` throws `SyncRejection(malformed_payload)` out of the `capture()` call itself, with nothing queued, reduced or signed. The failure names the cause at the line that caused it. Derive fixture ids (`uuid5`) instead of spelling them — a loosened codec is never the fix.
- **`todos.time_spent_minutes` is excluded from every cross-device comparison.** The op log never carries it — it is a dead cache (ADR-0030) — so comparing it would compare local defaults. It is not, however, unwritten: the column is NOT NULL, so the projector fills its declared default when it *creates* a row. `projector_view_notify_test.dart` guards that, and its view emulation is deliberately left unconstrained so a regression surfaces as a null on a raw row read rather than being masked by a SQL default.

- `harness/` — `FakeSyncServer` (the in-process contract double, with `connectAsUser` / `connectAsMember` mirroring the real credential split, and both the signal socket and the `GET /w/{w}/members` read hanging off the *member* session as they do on the server — the double models endpoints no client calls, because that is what lets a twin pin the credential a route requires, plus `injectUnchecked`, `poisonRegistry` and a Dart mirror of the signal hub for playing a hostile server), `SimDevice` (both stores, identity, HLC, `SignalListener`, `goOffline()`, `goSilent()` for a half-open socket, a gated/failing pull, a lost-POST-response fault, and a real enrolment ceremony), `SimWorkspace` (N devices of one User), `SimTimers` (a manually advanced timer wheel), `AuthorFixture` (the twin of `backend/tests/sync/builders.py`), `reduced_state.dart` (`canonicalReducedState`, the deterministic byte string convergence is asserted over, and `domainRows` for full-row table comparison), `signal_probe.dart` (`pumpEvents`, `PokeRecorder`), `rejection_matcher.dart` (`throwsRejection`, shared so a codec suite and a harness suite cannot assert a refusal to different strictnesses).
- **A `SimDevice` enrols the way a real one does.** Device A generates the passphrase and Root; every later device is handed *the passphrase string and nothing else* — no keypair, no store, no session. That is what makes "a second device enrols with the passphrase alone" a demonstration rather than an assumption, and it is why a test that needs a chained author calls `SimWorkspace.enrolFixture` instead of poking the registry. Argon2id runs for real at reduced costs, injected as **both** the parameters and the floor, so the floor check still runs on every blob and only the cost is smaller (`harnessKdfParameters`).
- `fake_sync_server_contract_test.dart` — the twin of `backend/tests/sync/test_ops_routes.py`, `test_recovery_escrow_routes.py`, `test_member_auth_routes.py` and `test_signal_socket.py`, case-for-case under the same names, asserting on the structured `detail.code` rather than on messages. **Keep them in step:** a convergence test is only evidence about the real system if the double behaves like the real server, and a missing twin is how that stops being true. The file's header lists the handful of backend cases that deliberately have none, and why — including the refresh-token cases, which the fake cannot express because it issues no bearer tokens at all.
- `realtime_signal_test.dart` — the payload-free signal end to end: an edit on A reaching B with no poll on B, a late-enrolling member's ops landing rather than quarantining, poke coalescing, the sync-failure policy, and the whole reconnect ladder (backoff schedule, `authParked`, terminal `failed`, idle deadline, protocol violation). Nothing in it sleeps: keepalives, the idle deadline and backoff all run on `SimTimers`. **No test in this file may use a real delay** — a wall-clock wait here is a flake waiting to be filed.
- `backend/tests/sync/test_signal_socket.py` — the binding no-payload assertion, over a real WebSocket via `httpx-ws`'s `ASGIWebSocketTransport`, plus the token cases the fake has no model for (including that a valid *user* session is refused with 4401, so the socket is not the weak door). Every session there runs the full enrolment ceremony, because the socket takes a member credential — from the shared `Session` / `open_session` / `found_workspace` helpers in `backend/tests/sync/builders.py`, which `test_ops_routes.py` and `test_grants_routes.py` use too, so the three cannot drift on what "a founded Workspace" means. Two harness quirks are load-bearing and documented in the file: the WS client is opened inside the test body (pytest-asyncio runs fixture setup and teardown in different tasks, which its anyio task group refuses), and a test must consume the handshake poke before issuing an HTTP request, because both share the one transaction-bound session. The keepalive interval and auth-frame deadline are `Settings` fields so those cases run in milliseconds.
- `backend/tests/sync/helpers.py` — the scaffolding the sync suite shares: `detail_of` (unwrap a route's structured `detail`) and `load_migration`/`run_migration` (apply one Alembic revision to a scratch engine). Fixtures stay in `conftest.py` and artifact minting in `builders.py`; these two were the chores each file used to re-copy, which is how an assertion and the thing it asserts drift apart.
- `backend/tests/sync/test_ops_author_chain_race_postgres.py` — the author-chain uniqueness constraint under a genuine concurrent write, and so the one part of the op-log contract the Dart double cannot mirror. It needs a Postgres `DATABASE_URL`: SQLite turns a write behind a stale read into a lock error rather than a constraint violation, which leaves the handler's recovery branch unreachable. Skips without one and fails rather than skips when `CI` is set. It calls the endpoint as a plain coroutine — no `Depends` resolves, so the session, the authenticated Member **and the signal hub** are all handed in by hand; a real subscribed hub is what lets it also pin the post-commit poke, including the one case only a race produces: a raced replay resolves to all duplicates and so pokes nobody.
- `convergence_test.dart` — enrolment, both-directions convergence, tombstones, offline queue and reconnect, replay idempotence, field-grain merge, the fail-closed quarantine surface, the reducer guards, author-side wire validation (a payload no receiver could apply is refused at `capture()`/`captureControl()` with the store, outbox and author chain untouched), and the trust cases: a poisoned registry, a fabricated MemberRegister, a genuine certificate wrapped around a forged envelope, and a zero chain link into a populated chain — each end to end through the spine.
- `grants_and_genesis_test.dart` — #549's acceptance criteria end to end: `workspace_genesis` and the log-state rule that decides who founds, Grants and the `(role, op_class)` matrix, grant-granular revocation, and the `epoch_floor` (raise-only, survives restart, and — the case a floor must not become — a raise that does not brick its own author's content writes). Every assertion is about what a *client* concludes, because the server's `workspaces` and `grants` tables are authoritative for nobody.
- `control_fork_test.dart` — two control ops naming one predecessor. The tie-break (earliest *certificate* HLC, then lowest author member id), the losing branch quarantined along with everything chaining through it, and the rebuild that follows because a resolved fork can change which content ops were authorized.
- `chain_verifier_test.dart` — the per-author chain rules as rules: gap, replay, fork, the idempotent re-serve, and the `(workspace, author, author_seq)` uniqueness constraint that backs the slot-collision verdict.
- `chain_integrity_test.dart` — the own-writes comparison and the integrity alarms it raises: a server that rolled our writes back, a substituted copy of our own op, and a server ahead of everything we authored.
- `enrolment_test.dart` / `recovery_escrow_test.dart` / `passphrase_policy_test.dart` — the ceremony's own edges (passphrase change, rollback and substitution *alarms*, below-floor blobs), the blob codec against real Argon2id and XChaCha20-Poly1305, and the entropy estimates behind the passphrase warning.
- `dao_capture_contract_test.dart` — one assertion per DAO write path: which ops it authors, on which entities, with which fields. This is the contract the flip rests on — a path that never described its effect is a write that silently does not sync — so a write path without a capture assertion is a test gap by construction. It also pins the two deliberate asymmetries: `deleteOutcome`'s enumerated cascade set, and the absence of the dead cache.
- `collection_round_trip_test.dart` — every collection, DAO write on A → reduce and project on B → the same row, column for column. Plus the dangling-reference cases: a TimeLog outliving its hard-deleted Outcome, a junction arriving before its parent.
- `merge_strategy_test.dart` — the ADR-0030 laws as laws (commutative, associative, idempotent), not as outcomes. A strategy that passes every vector and fails a law here is one refactor from breaking convergence.
- `projector_view_notify_test.dart` — ADR-0010 for the projector, per collection group, on a real on-disk sqlite_async database with the tables rewritten into PowerSync-shaped views. The negative case is asserted too: the same write without the notify leaves the watcher stale. Note the emulated backing table is deliberately *unconstrained* — PowerSync's `ps_data__*` is an id and a JSON blob, and carrying Drift's NOT NULL clauses over would make the emulation stricter than production.
- `full_day_convergence_test.dart` — capture → clarify → plan → focus (with an offline window) → preference races → evening shutdown, across two devices, then: A ≡ B on canonical bytes; a fresh device C reaching the same bytes by replay from zero; A rewinding its cursor and re-pulling unchanged; the whole log reduced in reverse order to the same bytes; and every domain table equal across all three as full rows.
- `sync_health_test.dart` — the `SyncHealth` stream from a real client and the indicator widget over fake streams.
- `envelope_vectors_test.dart` / `reducer_vectors_test.dart` — byte equality against the frozen fixtures in `spec/sync/`, which the Python suite asserts against too. **Never regenerate the vectors to make a test pass**: `backend/tools/generate_sync_vectors.py` is a hand-run tool, and a changed vector file is a protocol change to be reviewed as one. A reducer case may carry three optional keys: `permute` (the runner expands it to every application order and expects identical reduced state), `expected_clocks` (the stored per-field HLC — the only surface on which a non-LWW strategy's independent clock join is visible) and `strategy_overrides` (`{preference_key: strategy_name}`, the only way a case can select a strategy with no production key registration — which is how the `set_merge` cases reach it); `backend/tests/sync/test_reducer_vector_schema.py` keeps the generator and the Dart runner agreeing on that shape.

### Extending the vectors

Adding a merge case is a two-step, hand-run change: edit `_collection_and_strategy_cases` in `backend/tools/generate_sync_vectors.py`, then `cd backend && uv run python tools/generate_sync_vectors.py` and commit the re-frozen file with the diff reviewed as a protocol change. A case whose strategy has no production key registration selects it with `strategy_overrides`; nothing else can reach one. Expectations are written by hand, never computed — a generator that derived them would rewrite the thing it is supposed to be checked against. New cases append, so existing ones stay byte-identical.

Local verification for the whole slice:

Each line runs in its own subshell, so the two are pasteable as a block and both
`cd`s resolve from the repo root rather than the second one landing inside
`backend/`:

```bash
(cd backend && uv run ruff check . && uv run ruff format --check . && uv run mypy . && uv run pytest)
(cd app && fvm flutter analyze && fvm flutter test)
```

`flutter test` must run from `app/`: the vector loader reaches the repo-root `spec/` by relative path. The same applies to `app/test/cutover/`, which loads `spec/converge_verify/` the same way.

## Converge-verify (cutover tooling, #553 Phase 1)

The pre-cutover convergence check: does the phone's legacy PowerSync-side local store hold the same rows as the legacy mirrored Postgres tables? It is one-shot tooling the user runs and reviews before the Phase-2 reseed, and **#556 removes it** — `spec/converge_verify/`, `backend/app/converge_verify/`, `app/lib/cutover/`, `app/test/cutover/`, the `/settings/converge-verify` route, and the Settings entry, all of which carry the marker.

**How it works.** One canonical row serialisation, implemented twice — `app/lib/cutover/converge_verify/canonical_row.dart` and `backend/app/converge_verify/canonical.py` — and pinned against each other by the frozen vectors in `spec/converge_verify/canonical_row_vectors.json`. Per table, a column manifest gives an ordered `(column, kind)` list; a row canonicalises to a JSON array of normalised values, and its `row_digest` is the SHA-256 of that. The server publishes `count`, `null_id_row_count` and the full `id -> row_digest` map per table at `GET /converge-verify/report`; the device computes the same map over its own store and diffs.

Three properties are worth knowing before changing anything here:

- **The canonical encoder is hand-rolled on both sides, deliberately.** `jsonEncode` and `json.dumps` disagree on the case of `\u00xx` escapes for C0 controls, and the timestamp grammar spells its whitespace class as `[ \t]` rather than `\s` because the two regex engines cover different exotic code points. A digest that depended on which side computed it would make the whole check worthless.
- **The timestamp rules are frozen as *rules*, not as a captured serialisation.** The compose stack and the deployed stack run different powersync-service versions, so bytes captured from one are not evidence about the other — and the phone is the only store that matters. The parser accepts every shape either side can produce (Drift's space-before-offset, app-written UTC `Z` strings, Postgres microsecond offsets, zone-less legacy text) and truncates to millisecond precision.
- **Nothing throws on odd data.** A value a column kind refuses becomes a per-row anomaly with a sentinel in the canonical string; a NULL row id becomes `null_id_row_count`; a missing endpoint becomes a verdict. A throw would brick the report on the one device the check exists to inspect.

**What is not compared:** `user_id` on every table (server-derived from the JWT, so the server side is scoped by construction — and the local side is read *unfiltered* so a row stranded at `user_id = 'local'` surfaces as local-only), and `todos.time_spent_minutes` (the dead cache, excluded from the Phase-2 comparison too). The report publishes both exclusions and the screen shows them.

**Verdict rules.** A table is converged only when the id sets match, every shared id's digest matches, there are no anomalies on either side, and `null_id_row_count` is zero on both — a row with no id has no identity to match on, so it can never be shown to agree. The run's overall verdict is worst-news-first: `readOnlyProofFailed` (the tool cannot vouch for itself) outranks `serverNotDeployed` / `specVersionMismatch`, which outrank `notFullySynced` (pending uploads or dead letters mean the premise does not hold), which outranks `diverged`.

**Read-only is verified by effect, not asserted.** Each run snapshots the local per-table digests *and* `getUploadQueueStats().count` before and after — bracketing the server fetch too — and publishes the comparison both as `ReadOnlyProof` (asserted in `app/test/cutover/converge_differ_test.dart`) and as a line on the screen. `backend/tests/test_converge_verify.py` does the same for the server side by re-reading the rows the report described.

Automated coverage: `app/test/cutover/` (vectors, manifest-vs-`powersyncSchema` anti-drift, the differ over a seeded real store including the seeded-divergence acceptance case, the screen over scripted outcomes, and the detail request the runner builds — repeated `ids=` parameters, so an id carrying a comma or an `&` cannot be re-read as two ids the server has no rows for) and `backend/tests/test_converge_verify_canonical.py` + `test_converge_verify.py` (vectors, manifest-vs-SQLAlchemy anti-drift, the endpoints).

### Manual runbook

The Dart harness has no PowerSync engine (see the manual checklist above), so the true device path only runs by hand. Against the compose stack (`podman compose -f infra/docker-compose.yml up -d`) with a signed-in emulator:

1. **Converged pass.** Let sync settle, then Settings → *CUTOVER TOOLING* → **Converge-verify** → **Run check**. Expect `Converged — every table matches`, `upload queue 0, dead letters 0`, and `store digest unchanged`. The Settings entry sits between EVENING SHUTDOWN and ABOUT, well below the fold — scroll rather than trusting a tap coordinate; the section's position moves whenever a settings group is added, so no coordinate is recorded in the navigation table below.
2. **Seeded divergence — content.** Edit a row directly in the compose-stack Postgres (`podman compose -f infra/docker-compose.yml exec postgres psql -U jeeves -d jeeves -c "UPDATE todos SET title = 'edited server-side' WHERE id = '<id>'"`), re-run. Expect that table red, the row id under *Different content*, and **Compare columns** naming `title` and nothing else.
3. **Seeded divergence — delete side.** `DELETE FROM tags WHERE id = '<id>'` server-side, re-run: the id appears under *Only on this device*.
4. **Seeded divergence — insert side.** `INSERT` a row server-side for the signed-in user, re-run *before* it downloads: the id appears under *Only on the server*.
5. **Repeatability and read-only.** Revert the edits, re-run, and confirm it goes green again with the store digest unchanged across every run — that is the read-only and repeatable evidence end to end, on a real engine.
6. **Copy JSON** writes the whole report to the clipboard and to `adb logcat` (grep `converge-verify report`), which is the archival copy to paste into the issue.

On the user's actual phone the same steps apply minus the seeded divergences, and the backend deploy must have landed first: the endpoint is only present after a pipeline deploy, so a `Server not yet deployed` verdict means merged-but-not-deployed, not divergence.

## Enrolment ceremony (cutover tooling, #553 Phase 2)

The screen that runs `EnrolmentService` on the device: passphrase → Root → both escrow slots → member registration → per-Workspace genesis and this Device's owner Grant, and then — since #591 — `SyncLifecycle.activate`, so completing a ceremony is what starts syncing. **#556 removes the surface** (`app/lib/cutover/enrolment_ceremony/`, the `/settings/enrolment-ceremony` route and the Settings entry, all marked) but *not* the machinery underneath it — `app/lib/sync/` (including `sync_stack.dart`, `enrolment_state.dart`, `sync_lifecycle.dart`, `initial_upload*.dart` and `sync_store*.dart`), `providers/sync_stack_provider.dart`, `providers/sync_lifecycle_provider.dart`, `ApiService.sessionDio` and `services/secure_screen.dart` are permanent and carry no removal marker. The real onboarding flow that replaces the screen calls the same `activate()`.

**Three states, read from the store with no network.** A relaunched device holds no member credential — it is minted by the proof-of-possession exchange and never persisted — so the status has to be answerable offline:

- *not enrolled* — no stored keys **and** no pinned Root. The only state that offers founding.
- *half-founded* — either keys with a Workspace whose control log is still empty, or **a pinned Root with no keys at all**. The second is the one that is easy to get wrong: `enrolFirstDevice` writes the escrow and pins Root *before* it stores the keypairs, so a crash in that window leaves the account's escrow claimed by a device that cannot prove it, and founding again can only ever return `escrow_version_regression`. Both are recovered by re-entering the passphrase ("Enrol with the passphrase").
- *enrolled* — keys stored and every derivable Workspace founded. No founding control is rendered, and the runner refuses a second founding below the UI as well.

**What the surface does differently from converge-verify, on purpose.** No copy-to-clipboard for the passphrase (a clipboard manager or cloud clipboard sync would carry the encryption ceiling off the device — it is monospaced and selectable, to be written on paper); an explicit "I have written this down" checkbox gating the founding button, asked *before* the run so an interrupted ceremony still leaves the phrase in hand; and `FLAG_SECURE` on the window while the screen is mounted, because the recents thumbnail is a real capture that the system takes unprompted. The passphrase is rendered once and leaves the widget tree on success — the outcome's echo of it is never shown.

**Escrow conflicts arrive as `bad_escrow_signature` (403), not `escrow_version_regression` (409).** The server verifies the record's Root signature against the `root_pk` already in the slot before it compares versions, so a fresh device founding an already-founded account is refused for signing with its own Root. The version conflict is only reachable for the same Root re-writing its own slot, which the ceremony tolerates internally. Both classify as "an escrow already exists for this account", and both reveal the passphrase route on a device the store still reads as *not enrolled* — pre-filled with the phrase this session generated, into an empty field only. The reveal is sticky for the session and the field keeps what the user typed, because the phrase that claimed the escrow may be another device's and a mistyped correction must not withdraw the route or hand back the rejected phrase.

Automated coverage:

- `app/test/sync/enrolment_ceremony_runner_test.dart` — the real runner over the real `SyncStack`, against `FakeSyncServer`: founding, the refusal of a second founding (asserting the server saw no write), an offline run leaving the device un-enrolled, both crash windows and their passphrase resumes, the escrow conflict, and a second phone enrolling on the passphrase alone. **Deliberately not a `SimDevice` test:** a `SimDevice` hands every client the same omnipresent `DeviceLink` at construction, so it cannot notice a stack that fails to propagate the member transport to the preferences Workspace's client — the one place production diverges from the harness. Attaching that transport at construction instead of on every factory call makes the first case fail with `this device has no member credential yet`, which is exactly the bug the test exists for.
- `app/test/cutover/enrolment_ceremony_screen_test.dart` — the screen over a scripted runner, including the `FLAG_SECURE` set/clear pair. It sets a tall viewport: a `ListView` only inflates children near the visible window, so on the default 800px surface the checkbox and the founding button would be *absent* from the tree, and a finder that missed them would read as "the screen offers no founding" — a claim other cases in the file make on purpose.
- `app/test/cutover/enrolment_ceremony_status_test.dart` — the state table and the failure classification as pure functions.

### Manual runbook

The ceremony's real path needs a real key store and a real server, so it only runs by hand. Against the compose stack (`podman compose -f infra/docker-compose.yml up -d`) with a signed-in emulator:

1. **Sign in first.** The Workspace ids, the escrow slot and the Grants all derive from the account, so the screen refuses the `local` placeholder user with "sign in before enrolling this device".
2. Settings → *CUTOVER TOOLING* → **Enrolment ceremony**. Expect *Not enrolled*, and nothing else on offer but **Generate passphrase**. The section sits between EVENING SHUTDOWN and ABOUT, well below the fold — scroll rather than trusting a tap coordinate.
3. **Generate**, then confirm the checkbox, then **Found the Workspace**. Expect a few seconds of spinner (the Argon2id floor, on a background isolate) and then the enrolled panel: member id, escrow version 1, Root fingerprint, and both Workspaces marked *founded*.
4. **Verify server-side**: `podman compose -f infra/docker-compose.yml exec postgres psql -U jeeves -d jeeves -c "SELECT workspace_id, version FROM recovery_escrows"` shows two slots, and `SELECT workspace_id, author_member_id, author_seq, op_class FROM ops ORDER BY seq` shows two control ops per Workspace (genesis, then the root-signed owner Grant).
5. **Re-open the screen.** Expect the enrolled panel again, with no founding control of any kind.
6. **Airplane mode, fresh account.** Expect "Server unreachable", *Not enrolled* still on screen afterwards, and the generated passphrase still shown for the retry. The copy deliberately does **not** claim nothing was written: "unreachable" describes the request that failed, and a lost response to the escrow PUT is indistinguishable from one that never arrived — so it tells the user to keep the passphrase and, if a retry then reports an existing escrow, to enrol with it.
7. **Screen capture.** `adb shell screencap` on the ceremony screen returns a black frame while `FLAG_SECURE` is set, and a normal one on any other screen — which is also the check that the flag is being cleared on the way out.

**On the user's phone this is the Phase-2 human-in-the-loop step, and there is exactly one shot at it.** The passphrase is generated on the device, shown once, and is unrecoverable; write it on paper before tapping **Found the Workspace**, and do not leave the screen until it says enrolled. The enrolled panel (member id, escrow version, Root fingerprint, both Workspace ids) is the artifact to paste back into #553.

## Initial upload, and the reseed verification screen

The step the cutover rests on: author the phone's store onto the op-log spine as signed ops, then reduce the server log **from zero** on a throwaway stack and compare it with the source. The walk-and-author half is permanent product machinery — `app/lib/sync/initial_upload_plan.dart` and `initial_upload.dart`, triggered by enrolment — and only the *verification* half is cutover tooling. **#556 removes the surface** (`app/lib/cutover/reseed/`, `app/test/cutover/reseed*`, the `/settings/reseed` route and the Settings entry, all marked) but not the machinery underneath it — `app/lib/sync/` and `providers/sync_stack_provider.dart` are permanent.

**Sync starts at enrolment, and the walk is automatic.** `SyncLifecycle.activate` (`app/lib/sync/sync_lifecycle.dart`) runs it: no button, no verification gate, and a per-account row in `initial_upload_state` recording a completed pass. Automated coverage:

- `app/test/sync/sync_signup_flow_test.dart` — the E2E journey. A day of offline GTD through the real DAOs authors **zero** ops (the AC-3 regression, asserted rather than assumed), then enrolment plus one `activate()` puts the store on the log and drains the queue, then a second device enrolling with the passphrase alone converges on identical reduced-state bytes *and* identical domain rows while authoring nothing itself. Plus an interrupted pass resuming with nothing re-authored.
- `app/test/sync/sync_lifecycle_test.dart` — the parts a journey cannot reach, over `FakeSyncServer` and a real `SyncStack`: the **relaunch**, which is where the process-death resume is actually pinned (a fresh stack over the same files has no member credential — it is memory-only by design — and one `activate()` re-mints it by proof of possession, after which the preferences client picks it up through `SyncStack`'s factory propagation); un-enrolled and half-founded both activating nothing; a refused entity recorded without holding the marker open; the marker keyed per account.
- `app/test/sync/workspace_routing_capture_test.dart` — the production capture binding, routing asserted by reading the outbox's `workspace_id` rather than by watching a spy.
- `app/test/sync/sync_status_mapping_test.dart` — `syncStatusFor` as a pure table, including that an unresolved alarm outranks a busy queue.
- `app/test/sync/harness/stack_phone.dart` — a phone assembled the way `syncStackProvider` assembles one and **un-enrolled at construction**, which is what a `SimDevice` cannot be. It is also the only way to exercise the member-transport propagation, since a `SimDevice` hands every client the same link up front.

**How the verification screen works.** Three parts, one shared transform:

- `sync/initial_upload_plan.dart` is pure: domain rows in, planned ops out. Per-collection field encoding through the shipped codecs (`dateTime` columns normalised by the same timestamp grammar converge-verify uses, TEXT timestamp columns passed through byte for byte, `user_id` **stamped** with the enrolled account), junction and `user_preferences` ids rewritten to their derivations, and ADR-0025's auto-resolve. Both the uploader and the verifier read this one plan, so the comparison cannot degenerate into two normalisers agreeing with each other.
- `sync/initial_upload.dart` authors it through `SyncClient.capture` — the production path, so the codecs, the receive-codec round trip, the author-side guards (#573, ADR-0033), the HLC, the signature and the outbox are all the real ones — and flushes on a cadence.
- `reseed_verifier.dart` builds a scratch stack per Workspace (fresh `SyncDatabase`, scratch `SyncClient` with the live device's identity, clock, member transport and Root pin, fresh `Reducer` with the production strategy registry, a `DomainProjector` into a scratch `GtdDatabase`) and pulls from cursor 0.

Five properties are worth knowing before changing anything here:

- **Idempotence is a diff against the target, not a memory of the run.** Op ids stay random UUIDv4s. A derived op id would be actively wrong: `op_id` travels inside a signed header beside `author_seq`, `prev_author_hash` and the payload's HLC, and a restarted run structurally cannot reproduce those — so it would claim an already-spent `(workspace, author, op_id)` slot and every peer would read the differing envelope as a rewrite. Instead the uploader skips an entity whose **planned fields** the spine already reduces to, which is airtight because `capture()` reduces locally before it returns. Only the planned fields are compared: an entity carrying a field from some other source must still count as present, or the skip counter lies. A planned null must be *present and null* to count. A restart does not fork the chain — the head comes from the persisted `author_state` row.
- **The comparison is over reduced state, not the scratch domain rows.** Reduced fields hold the canonical wire values verbatim; Drift's default `dateTime` storage is unix *seconds*, so a domain-row comparison would manufacture sub-millisecond mismatches that say nothing about the data. Projection still runs, and what it held back (required columns unsatisfied) is reported per table.
- **A row the upload cannot carry is excluded and named, never uploaded half-formed.** A NULL *required* column — `todos.title` is the one that happens, and PowerSync's views permit it — means no op could ever project, so the row is left out of the plan and the verdict is `partiallyReseeded` rather than green. Optional NULLs are authored as explicit nulls, so a re-run cannot leave a stale value standing.
- **ADR-0025 is applied here.** An Outcome holding several Areas keeps the one whose `(casefolded name, id)` sorts first — a pure function, so every re-run picks the same one — and each surplus membership becomes membership of the Label named after that Area: an existing legacy Label of that name (same-name Labels resolved by the same total order), else one the spine already holds from an earlier run, else a freshly minted Tag. Duplicate junction rows for one pair are one membership, not two Areas. The pick is **provisional**: the real resolution is the user's, in the next Weekly Review, and the report's conversion list is that pass's worklist. A Label an earlier run minted has no legacy row, so a later run endorses it by id rather than re-asserting it — the ids are in the report.
- **Read-only, verified by effect — and what that means changed with the flip (#591).** Each run snapshots the domain store's per-table digests *and* PowerSync's upload-queue count before and after, bracketing the authoring and the verification, and publishes the comparison. The spine is written on purpose, so it is not in the proof. Post-flip the projector *is* attached, so a run that actually authors something writes the domain store by design and the proof legitimately reads CHANGED. That is not the case the screen is for: the initial upload has already run at enrolment, so a verification run finds everything skipped, authors nothing, and the digests hold. A CHANGED proof on this screen now means "this run had work to do", which is itself worth knowing before reading the rest of the report.

**Verdict rules.** Worst-news-first, like converge-verify's: `readOnlyProofFailed` (the tool cannot vouch for itself) outranks `notEnrolled`, which outranks `uploadIncomplete` (ops still queued after the final flush, so the server does not hold what was authored), which outranks `diverged`, which outranks `partiallyReseeded`. `notEnrolled` covers the whole class of "there is no reading to report": a member credential missing on either Workspace, a Root unpinned on either Workspace (both get a scratch stack, so one pin is not enough), and a run that never reached the pull — the strongest verdict is gated on the premise rather than trusted from the caller, because a comparison over zero tables would otherwise pass vacuously. A table is converged only when the planned and reduced entity-id sets match, every shared id's canonical digest matches, nothing was held back by the projector, and there are no anomalies on either side.

Automated coverage, split the way the code is — the transform and the uploader are sync-layer tests, the verification surface is cutover:

- `app/test/sync/initial_upload_plan_test.dart` — the transform as a pure function: field-encoding vectors, id derivations, and the ADR-0025 cases.
- `app/test/sync/initial_upload_test.dart` — the diff skip and its null convention, re-assertion, the flush cadence, preference routing, and the ADR-0033 guard firing at the author's own call site.
- `app/test/cutover/reseed_round_trip_test.dart` — the whole ceremony over a real `SimDevice` and `FakeSyncServer`, against a seeded legacy store: the converged pass, the ADR-0025 resolution enumerated, the duplicate-junction collapse, an interrupted run (offline, so every capture succeeds and the flush fails) completing with **zero** ops re-authored and one content op per planned entity on the server, a legacy edit between runs re-asserting exactly one entity, a re-run minting no second Label, the NULL-title row left behind, and preferences routed into their own Workspace.
- `reseed_legacy_store.dart` — the domain-store double, whose schema is **derived from `powersyncSchema`** rather than hand-copied. That is load-bearing: PowerSync declares `todos.clarified` / `priority` / `time_estimate` as INTEGER columns, so `getAll` hands the reseed an `int`; an all-TEXT double would hand it `'1'`, every integer and boolean field would be refused as unencodable, and the suite would be asserting against a store the phone does not have. The NOT NULLs and CHECKs are deliberately *not* copied — a NULL `title` has to be representable.
- `reseed_report_test.dart` — the verdict ordering and the archival JSON.
- `reseed_screen_test.dart` — the surface over scripted outcomes. It sets a tall viewport for the same reason the enrolment screen test does.

### Manual runbook (reseed verification)

Optional since #591 — enrolment authors the store on its own, and this screen only *checks* that it did. Preconditions: an *enrolled* device (the screen refuses otherwise) and sync settled. Against the compose stack (`podman compose -f infra/docker-compose.yml up -d`) with a signed-in emulator:

1. **Converge-verify first**, then Settings → *CUTOVER TOOLING* → **Reseed** → **Run reseed**. The section sits between EVENING SHUTDOWN and ABOUT, well below the fold — scroll rather than trusting a tap coordinate.
2. Expect the stage line to walk *preconditions → sync → plan → author → verify*, then `Reseeded — the spine reduces to the same store`, `0 op(s) still queued`, and `store digest unchanged`.
3. **Verify server-side**: `podman compose -f infra/docker-compose.yml exec postgres psql -U jeeves -d jeeves -c "SELECT workspace_id, count(*) FROM ops WHERE op_class = 1 GROUP BY workspace_id"` shows one content op per planned entity, split across the two Workspaces.
4. **Run it again.** Expect the same verdict with `0 authored`, everything *already present*, and the same store digest — that is idempotence on a real engine.
5. **Interrupt it.** Airplane mode mid-run: expect a transport error, then re-run online and expect `0 authored` again with everything skipped (a run that got as far as authoring) or a normal pass (one that did not). The op count from step 3 must not have doubled.
6. **Edit a row on the old stack between runs**, re-run, and expect exactly one entity re-asserted and the verdict still green.
7. **Copy JSON** writes the whole report to the clipboard — that is the copy to paste into the issue. Only the verdict goes to `adb logcat` (grep `reseed report copied`), unlike converge-verify: this report carries legacy content (Outcome titles, Tag names) through the plan, and the log is readable by any bug report taken afterwards. A lost clipboard is a re-run away.

**Nobody is required to run this.** Unlike the enrolment ceremony there is no one-shot secret, so it is safe to re-run at any time. What it is good for after a real cutover: the ADR-0025 conversion list is the worklist to carry into the next Weekly Review, and any row under *Not carried* is a row the spine does not have — fix it in the app (give the Outcome a title) and that edit authors an ordinary op through the capture seam, which is how it reaches the spine. No further automatic initial upload runs: the marker records a completed pass. Re-running *this* screen is what re-asserts changed rows through the initial-upload diff.

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
