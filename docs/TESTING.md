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
- **A live Drift `watch()` reached from a widget test hangs the run.** Drift's `StreamQueryStore` keeps a pending timer alive, and the test binding owns the clock, so `pumpAndSettle` never settles: it spins until its 10-minute default timeout, which looks like an infinite hang rather than a failure. Two shapes to avoid:
  - *Awaiting a stream directly* (`await db.captureDao.watchInbox().first`) — the first event is never delivered and the isolate blocks so hard the per-test timeout can't fire. Read with a plain `select` instead.
  - *A widget under test subscribing to one* (a `StreamProvider` backed by `query.watch()`). Either override the provider with `Stream.value(...)` in the harness — what `clarify_card_test.dart` and `process_to_handlers_test.dart` do — or, if the surface never renders the data live, have it do a one-shot read instead of a watch. `ClarifyCard` selects between the two with `ClarifyTagSection`: `draftInputOnly` renders no tag chips and reads the hints once via `CaptureDao.tagHintsForCapture`, so `clarify_surface_parity_test.dart` deliberately leaves `captureTagHintsProvider` un-overridden — if that option ever starts watching, the file hangs instead of passing quietly.
- **In an adopter's test, never `find.byKey` an `AppTitleBar` action directly.** Where a bar action renders depends on the width breakpoint (see DESIGN.md § App title bar): the same action sits in the bar on a wide surface and inside the ⋮ menu on a narrow one, so a screen test that finds it directly passes or fails by accident of the test surface size. Adopter (screen) tests go through `findBarAction(tester, key)` / `tapBarAction(tester, key)` from `test/helpers/app_title_bar_test_helpers.dart`, which look in the bar first and open the ⋮ menu when the action is not there. The exception is a test that is *specifically* asserting in-bar placement — e.g. that an action was demoted to an in-bar icon rather than overflowed — which scopes its finder to the `AppTitleBar` (`find.descendant(of: find.byType(AppTitleBar), …)`) and pins a known surface width. The component's own tests (`app_title_bar_test.dart`), which drive the surface width themselves, may assert bar internals directly. The budget arithmetic itself (`actionBudget`, `splitActions`) is pure and unit-tested without pumping a widget.
- **Never wait for a real-async drift write with a fixed sleep.** An in-memory drift write completes on the real event loop in microseconds; a `runAsync(Future.delayed(...))` "settle" charges its full duration on every host and masks hangs. Use `settleWithRealAsync(tester)` from `test/helpers/settle.dart` (drains the real event queue via a bounded `runAsync(() => pumpEventQueue())`, then `pumpAndSettle`) — if a test ever needs more than one real-async turn, raise its `rounds` parameter rather than reinstating a sleep.
- **`tester.tap` on a `ListView` child below the fold silently does nothing.** A `ListView` builds children within its `cacheExtent` while they still sit below the viewport, so the widget is findable but a tap at its centre hit-tests empty space (only a "would not hit test" warning). Worse, a child *beyond* the cacheExtent is not built at all, so the finder returns nothing and `ensureVisible` throws `Bad state: No element`. Drag until the finder is non-empty, then `ensureVisible`, then tap — see `_scrollAndTap` in `inbox_clarify_screen_test.dart` / `clarify_card_test.dart`.
- **`tester.enterText` leaves the field focused, so a focus-loss save has not happened yet.** Surfaces that save text on focus loss — `TaskDetailScreen`, `ActiveFocusScreen`, `ClarifyCard.forOutcome` (ADR-0023) — write nothing while the user is still in the field. A test that types and immediately asserts on the row is reading the *pre-edit* value, and reads as a broken save rather than a missing trigger. Drop focus first (`FocusManager.instance.primaryFocus?.unfocus()`, then pump) — see `_loseFocus` in `clarify_card_test.dart`. Assert **before** unmounting, too: a dispose-time flush would otherwise make a working focus-loss save and a broken one indistinguishable.
- **A focused text field keeps its wizard page mounted, so "the step unmounted" assertions lie.** `EditableText` is an `AutomaticKeepAliveClientMixin` client and wants to be kept alive while it holds focus, so a `PageView` step whose field is still focused stays in the tree off-screen when the wizard advances. `find.byKey` skips off-screen widgets by default, so the step *looks* gone while its `State` — and its controllers — quietly survive: a test of anything that happens on unmount (the `ClarifyRetention` stash, a dispose-time flush) then passes with the production code deleted. Drop focus before crossing the boundary, and assert the teardown with `skipOffstage: false` — see the step-crossing retention test in `focus_session_planning_back_test.dart`.
- **`ref.read` of a provider the widget never watches returns its initial state, not the real one.** A `StreamProvider` read for the first time inside a button callback is still `AsyncLoading`, so `status.asData?.value` is null and a `?? 'unknown'` fallback fires on every run — the surface looks wired up and quietly records the wrong value. The subscription has to exist before the callback: `ref.watch` it in `build` and pass the resolved value into the handler. A test that overrides the provider with `Stream.value(...)` does *not* paper over this; it reproduces it exactly, which is how it was caught. Watching is necessary but not sufficient: read the value as `status.value`, because a provider rebuilt by one of *its* dependencies sits in `AsyncLoading` still carrying the last real value, and `asData` is null there too — reproduce that state by overriding the provider with a body that watches a throwaway provider, then invalidating it.
- **Restore `debugPrint` inside the test body, never in `addTearDown`.** To assert on what a widget logged you swap `debugPrint` for a collector, but it is a foundation debug variable and the harness runs `debugAssertAllFoundationVarsUnset` at the end of the *test body* — before any tear-down fires. Restoring via `addTearDown` therefore fails every time with "The value of a foundation debug variable was changed by the test", pointing at the test rather than at the restore. Wrap the logging window in `try`/`finally` and reassign the original there; see the refresh-error case in `async_subject_test.dart`.
- **A deeply-nested worktree path can break `flutter test` before a single test runs.** The native-assets step relinks a bundled dylib with `install_name_tool`, which fails when the rewritten install name does not fit the dylib's existing header padding: `changing install names or rpaths can't be redone … larger updated load commands do not fit`. The dylib was built for a path under the repo root, so a worktree nested a few levels deeper than that overflows the padding. Deleting `app/build/native_assets` does not help — the next run rebuilds it at the same long path and fails identically. (The engine whose dylib first surfaced this is gone, but the mechanism is generic to any bundled native asset.)

  Two things make this expensive to diagnose. It reports as a *build* error, not a test failure, so the run produces no test counts at all; and piping the command through `tail` discards the non-zero exit status, so a run that executed zero tests reads as a pass. Create agent worktrees at a short path (`/tmp/<name>`), and capture exit codes explicitly (`cmd > log 2>&1; echo "exit=$?"`) rather than trusting a piped summary line.

- **Pre-commit hook and the shared FVM SDK cache**: `.githooks/pre-commit`'s self-heal step (which rewrites `bin/cache/flutter.version.json` before `dart run build_runner`, since a sibling worker's run can knock that file out mid-commit) runs `flutter --version` from *inside the resolved SDK's own directory*, never from `app/`. Flutter derives the identity it writes into that cache from the git repo of its cwd, so running it from `app/` would stamp *Jeeves's* revision into the shared SDK cache instead of Flutter's own — corrupting `bin/cache/flutter.version.json` for every worktree and worker sharing that SDK (`{"flutterVersion":"0.0.0-unknown","repositoryUrl":".../Jeeves.git",...}`), after which `dart pub` fails version solving machine-wide until the cache is repaired. See `.githooks/tests/test-pre-commit-hook.sh` for the regression coverage.

  Linked worktrees don't carry their own `app/.fvm/flutter_sdk` (it's gitignored and only materialized by `fvm use`), so the hook's resolution loop also checks the main checkout's — resolved via `git rev-parse --git-common-dir`, which always points at the main worktree's `.git` regardless of which worktree is running the hook. If no SDK can be resolved anywhere (local, main checkout, or the system fallback paths), the hook fails loudly with a clear message rather than silently running with no `flutter`/`dart` on `PATH`.

  The `cd` into the SDK's directory isn't sufficient by itself: when `git commit` runs the hook from a linked worktree, it sets `GIT_DIR`/`GIT_INDEX_FILE` (and other `GIT_*` vars) in the hook's own environment, pointing at the worktree's git-dir. Those survive the `cd` — git prefers an explicit `GIT_DIR` over cwd-based discovery — so flutter's internal git calls would still resolve to Jeeves unless the hook clears them first (`unset $(git rev-parse --local-env-vars)`) before invoking `flutter --version`.

  If the shared cache is ever corrupted by some other means (e.g. running `flutter --version` by hand from inside `app/`), confirm the diagnosis by reading `frameworkRevision` in `bin/cache/flutter.version.json`: if it matches a *Jeeves* commit rather than a Flutter one, the SDK computed its version from this repo. Repair by running `flutter --version` from inside the SDK's own directory (e.g. `(cd ~/fvm/versions/<version> && bin/flutter --version)`), not from `app/`.

- **Pre-commit hook and a worktree without `backend/.venv`**: `backend/.venv` is gitignored and only ever materialized by `uv sync`, so a freshly created linked worktree has none — run `cd backend && uv sync --extra dev` before your first commit that touches `backend/`. The hook checks for `backend/.venv/bin/activate` and fails with that command named, rather than sourcing it blind.

  The guard matters because the unguarded source was **interpreter-dependent, not fail-safe**. Git runs the hook through its `#!/bin/sh` shebang, and in POSIX mode (`/bin/sh`, dash) `.` is a special builtin, so a failed `. .venv/bin/activate` terminates the script: the hook did return non-zero and git did refuse the commit, but all the operator got was a raw line-number error naming no remedy. Outside POSIX mode — **`zsh`, and plain `bash`** — the same failure is non-fatal: execution falls through to the unactivated `ruff`/`mypy`/`pytest` calls, and where those resolve on the outer `PATH` they "pass" against the wrong environment and the hook reaches `exit 0`. `exit 0` is the hook telling git to proceed, so the commit *is* made — printing `✅ All pre-commit checks passed!` over checks that never ran against the venv (#539, same false-green genre as #537). Either way the operator has no actionable signal, so the prerequisite is asserted explicitly rather than left to the interpreter's `.` semantics.

  Note the shape of the original report ("exits 0 without committing"): a hook abort under `/bin/sh` blocks the commit, so an exit status of 0 observed alongside nothing committed means the *real* non-zero status was swallowed on the way out — the same piped-command trap recorded for #537 above. Capture `git commit`'s exit code directly, and confirm the commit with `git log --oneline -1` and `git status --porcelain`.

  `.githooks/tests/test-pre-commit-hook.sh` covers this, and deliberately runs every backend case under **every shell present — `sh`, `bash`, and `zsh`**. `sh` is the production path and pins the POSIX-mode abort; `bash` and `zsh` pin the fall-through that reaches `exit 0`, which an `sh`-only suite would have gone green on. (`sh` and `bash` are distinct runs even where `/bin/sh` *is* bash, since POSIX mode is what makes the failed source fatal.)

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

Merge is covered automatically, at three levels: the per-key strategy function
(`app/test/services/user_preferences_conflict_test.dart`), the reducer's field-grain
arbitration against the shared golden vectors (`spec/sync/reducer_v1_vectors.json`,
read by both the Dart and the Python reducer), and two simulated devices converging
end to end (`app/test/sync/convergence_test.dart`). There is no engine behaviour left
outside the harness, so nothing here is manual by necessity.

What still wants a device is the part the harness models rather than runs — a real
server, real HLC skew, two physical devices:

- **Snooze floors never regress (`maxTimestampValue`).** Snooze a notification further into the future on device A, then let an older write carrying a nearer snooze value arrive from device B; confirm the later "until" survives and the notification stays silenced. Confirm an explicit un-snooze (tombstone) clears the floor even against a live value.
- **An offline write survives a reconnect.** Toggle a preference on device A while the server is unreachable, cold-restart the app (which rebuilds `syncedPreferencesProvider` from the store), then reconnect. Assert on `dao.getAll(userId)` / the row, not on notifier state, because the in-memory merge can mask a wiped row.
- **Set/list keys merge (`setMerge`).** No production key uses this today; when one is added, make two concurrent additions on two devices and confirm both survive.

## The Minimal Sync Server harness (automated)

The op-log stack (`app/lib/sync/`, `backend/app/sync/`) is built to be runnable in a Dart test, and `app/test/sync/` is where that pays off — N simulated devices, each with **both** of its stores and its own keypair, on a shared manually advanced clock, against an in-process server double. It is the whole client sync path, so there is no engine behaviour sitting outside it; the checklist above covers what a harness models rather than runs (a real server, real clock skew, two physical devices).

A `SimDevice` is a whole device: a `SyncDatabase` (the convergence substrate), a `GtdDatabase` wired with the production `WorkspaceRoutingOpCapture` (so the real DAOs author real ops, and a DAO-path preference write routes into the preferences Workspace rather than the GTD one), and a `DomainProjector` feeding the domain store back from reduced state. It enrols at construction; `harness/stack_phone.dart` is the sibling for cases that need a device that is *not* yet enrolled, built over a real `SyncStack`. Two consequences worth knowing before writing a case:

- **Entity ids must be canonical lowercase UUIDs.** The payload codec rejects anything else rather than normalising it, and since #573 authoring runs that same codec: a fixture id like `'outcome-1'` throws `SyncRejection(malformed_payload)` out of the `capture()` call itself, with nothing queued, reduced or signed. The failure names the cause at the line that caused it. Derive fixture ids (`uuid5`) instead of spelling them — a loosened codec is never the fix.
- **Cross-device row comparison excludes no column.** Every column on the domain tables is either synced through the op log or derived at read time, so two converged devices hold byte-identical rows and `domainRows` is called with no `exclude` set. (The former exception, `todos.time_spent_minutes`, was a dead cache dropped in #604.)

- `harness/` — `FakeSyncServer` (the in-process contract double, with `connectAsUser` / `connectAsMember` mirroring the real credential split, and both the signal socket and the `GET /w/{w}/members` read hanging off the *member* session as they do on the server — the double models endpoints no client calls, because that is what lets a twin pin the credential a route requires, plus the key plane — the three wrap routes, `rotate` materialisation and the stale-epoch refusal, with `keyWrapRecipients` and `keyedEpochs` so a test asserts on the server's *own* rows rather than on what a ceremony believed it uploaded — and `injectUnchecked`, `poisonRegistry`, `poisonGrantLiveness` and a Dart mirror of the signal hub for playing a hostile server), `SimDevice` (both stores, its own `WorkspaceKeyStore`, identity, HLC, `SignalListener`, `goOffline()`, `goSilent()` for a half-open socket, a gated/failing pull, a lost-POST-response fault, and a real enrolment ceremony), `SimWorkspace` (N devices of one User, `enrolFixture` for a chained granted Device and `enrolServiceFixture` for the one Member kind no epoch key can be wrapped to), `SimTimers` (a manually advanced timer wheel), `AuthorFixture` (the twin of `backend/tests/sync/builders.py`), `reduced_state.dart` (`canonicalReducedState`, the deterministic byte string convergence is asserted over, and `domainRows` for full-row table comparison), `signal_probe.dart` (`pumpEvents`, `PokeRecorder`), `rejection_matcher.dart` (`throwsRejection`, shared so a codec suite and a harness suite cannot assert a refusal to different strictnesses).
- **A `SimDevice` enrols the way a real one does.** Device A generates the passphrase and Root; every later device is handed *the passphrase string and nothing else* — no keypair, no store, no session. That is what makes "a second device enrols with the passphrase alone" a demonstration rather than an assumption, and it is why a test that needs a chained author calls `SimWorkspace.enrolFixture` instead of poking the registry. Argon2id runs for real at reduced costs, injected as **both** the parameters and the floor, so the floor check still runs on every blob and only the cost is smaller (`harnessKdfParameters`).
- `fake_sync_server_contract_test.dart` — the twin of `backend/tests/sync/test_ops_routes.py`, `test_recovery_escrow_routes.py`, `test_member_auth_routes.py`, `test_keywrap_routes.py` and `test_signal_socket.py`, case-for-case under the same names, asserting on the structured `detail.code` rather than on messages. **Keep them in step:** a convergence test is only evidence about the real system if the double behaves like the real server, and a missing twin is how that stops being true. The file's header lists the handful of backend cases that deliberately have none, and why — including the refresh-token cases, which the fake cannot express because it issues no bearer tokens at all.
- `realtime_signal_test.dart` — the payload-free signal end to end: an edit on A reaching B with no poll on B, a late-enrolling member's ops landing rather than quarantining, poke coalescing, the sync-failure policy, and the whole reconnect ladder (backoff schedule, `authParked`, terminal `failed`, idle deadline, protocol violation). Nothing in it sleeps: keepalives, the idle deadline and backoff all run on `SimTimers`. **No test in this file may use a real delay** — a wall-clock wait here is a flake waiting to be filed.
- `backend/tests/sync/test_signal_socket.py` — the binding no-payload assertion, over a real WebSocket via `httpx-ws`'s `ASGIWebSocketTransport`, plus the token cases the fake has no model for (including that a valid *user* session is refused with 4401, so the socket is not the weak door). Every session there runs the full enrolment ceremony, because the socket takes a member credential — from the shared `Session` / `open_session` / `found_workspace` helpers in `backend/tests/sync/builders.py`, which `test_ops_routes.py` and `test_grants_routes.py` use too, so the three cannot drift on what "a founded Workspace" means. Two harness quirks are load-bearing and documented in the file: the WS client is opened inside the test body (pytest-asyncio runs fixture setup and teardown in different tasks, which its anyio task group refuses), and a test must consume the handshake poke before issuing an HTTP request, because both share the one transaction-bound session. The keepalive interval and auth-frame deadline are `Settings` fields so those cases run in milliseconds.
- `backend/tests/sync/helpers.py` — the scaffolding the sync suite shares: `detail_of` (unwrap a route's structured `detail`) and `load_migration`/`run_migration` (apply one Alembic revision to a scratch engine). Fixtures stay in `conftest.py` and artifact minting in `builders.py`; these two were the chores each file used to re-copy, which is how an assertion and the thing it asserts drift apart.
- `backend/tests/sync/test_ops_author_chain_race_postgres.py` — the author-chain uniqueness constraint under a genuine concurrent write, and so the one part of the op-log contract the Dart double cannot mirror. It needs a Postgres `DATABASE_URL`: SQLite turns a write behind a stale read into a lock error rather than a constraint violation, which leaves the handler's recovery branch unreachable. Skips without one and fails rather than skips when `CI` is set. It calls the endpoint as a plain coroutine — no `Depends` resolves, so the session, the authenticated Member **and the signal hub** are all handed in by hand; a real subscribed hub is what lets it also pin the post-commit poke, including the one case only a race produces: a raced replay resolves to all duplicates and so pokes nobody.
- `convergence_test.dart` — enrolment, both-directions convergence, tombstones, offline queue and reconnect, replay idempotence, field-grain merge, the fail-closed quarantine surface, the reducer guards, author-side wire validation (a payload no receiver could apply is refused at `capture()`/`captureControl()` with the store, outbox and author chain untouched), and the trust cases: a poisoned registry, a fabricated MemberRegister, a genuine certificate wrapped around a forged envelope, and a zero chain link into a populated chain — each end to end through the spine.
- `grants_and_genesis_test.dart` — #549's acceptance criteria end to end: `workspace_genesis` and the log-state rule that decides who founds, Grants and the `(role, op_class)` matrix, grant-granular revocation, and the `epoch_floor` (raise-only, survives restart, and — the case a floor must not become — a raise that does not brick its own author's content writes). Every assertion is about what a *client* concludes, because the server's `workspaces` and `grants` tables are authoritative for nobody.
- `e2ee_test.dart` — #554's acceptance criteria end to end: turn-on (every content op after it is `aead_v1` and no marker byte survives on the wire, while the pre-turn-on history stays plaintext and stays readable), a fresh device converging on the passphrase alone through the escrow wraps, the two encryption *alarms*, revoke-plus-rotate, the ceremony that refuses before authoring, the scheduled-rotation trigger, and a Workspace keyed at genesis. Two of its cases look like duplicates and are not: a **tampered ciphertext** is `signature_invalid`, because the signature covers `header ‖ body` and the order is verify-then-decrypt, so an `aead_failure` needs an author that really signed bytes that do not open. No test hands an epoch key from one device to another, exactly as none hands one a Root.
- `control_fork_test.dart` — two control ops naming one predecessor. The tie-break (earliest *certificate* HLC, then lowest author member id), the losing branch quarantined along with everything chaining through it, and the rebuild that follows because a resolved fork can change which content ops were authorized.
- `chain_verifier_test.dart` — the per-author chain rules as rules: gap, replay, fork, the idempotent re-serve, and the `(workspace, author, author_seq)` uniqueness constraint that backs the slot-collision verdict.
- `chain_integrity_test.dart` — the own-writes comparison and the integrity alarms it raises: a server that rolled our writes back, a substituted copy of our own op, and a server ahead of everything we authored.
- `enrolment_test.dart` / `recovery_escrow_test.dart` / `passphrase_policy_test.dart` — the ceremony's own edges (passphrase change, rollback and substitution *alarms*, below-floor blobs), the blob codec against real Argon2id and XChaCha20-Poly1305, and the entropy estimates behind the passphrase warning.
- `dao_capture_contract_test.dart` — one assertion per DAO write path: which ops it authors, on which entities, with which fields. This is the contract the flip rests on — a path that never described its effect is a write that silently does not sync — so a write path without a capture assertion is a test gap by construction. It also pins the two deliberate asymmetries: `deleteOutcome`'s enumerated cascade set, and the absence of the dead cache. And it pins the negative half of the same contract — an absent Outcome authors *nothing*, including when a junction row survives it — since a write path can be wrong by describing an effect it did not have as easily as by describing none.
- `collection_round_trip_test.dart` — every collection, DAO write on A → reduce and project on B → the same row, column for column. Plus the dangling-reference cases: a TimeLog outliving its hard-deleted Outcome, a junction arriving before its parent.
- `merge_strategy_test.dart` — the ADR-0030 laws as laws (commutative, associative, idempotent), not as outcomes. A strategy that passes every vector and fails a law here is one refactor from breaking convergence.
- `projector_view_notify_test.dart` — ADR-0010 for the projector, per collection group, over the production store topology: a real on-disk sqlite_async database whose synced names are the real tables Drift created. The projector writes through `customStatement` with no `updates:` set, so the notify is what a watcher reading across a collection group depends on.
- `domain_rebuild_test.dart` — a fresh domain store rebuilt from a real device's op log: reduced state lands, a tombstoned entity does not come back, an empty log leaves an empty store, and a second run produces the same rows (ADR-0035).
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

`flutter test` must run from `app/`: the vector loader reaches the repo-root `spec/` by relative path.

## Enrolment ceremony (the onboarding surface)

The screen a signed-in but un-enrolled device is routed to, and cannot leave except by
signing out (`app/lib/screens/enrolment/`, route `/enrolment`). It runs
`EnrolmentService` on the device: passphrase → Root → both escrow slots → member
registration → per-Workspace genesis and this Device's owner Grant, and then
`SyncLifecycle.activate` — so completing a ceremony is what starts syncing.

**Two doors, chosen from the account rather than the store.** An un-enrolled store reads
identically on the first device of a new account and the second device of one already
founded, and only the first can found — the escrow PUT from the second could only ever be
refused. So the screen probes `EnrolmentCeremonyRunner.escrowExists()` over the User
credential:

- **empty slot → found.** Generate a passphrase, confirm it is written down, found.
- **occupied slot → join.** Passphrase field only; no founding control is drawn.
- **probe unreachable → retry.** Neither door can open offline, so the screen says so
  instead of drawing a button whose only outcome is a failure. A passphrase already
  generated in this session keeps the founding block on screen even then — hiding it
  would take the only copy of the phrase with it.

**Three store states, read with no network.** A relaunched device holds no member
credential — it is minted by the proof-of-possession exchange and never persisted — so the
status has to be answerable offline:

- *not enrolled* — no stored keys **and** no pinned Root. The state the two doors above
  arbitrate between.
- *half-founded* — either keys with a Workspace whose control log is still empty, or **a
  pinned Root with no keys at all**. The second is the one that is easy to get wrong:
  `enrolFirstDevice` writes the escrow and pins Root *before* it stores the keypairs, so a
  crash in that window leaves the account's escrow claimed by a device that cannot prove
  it, and founding again can only ever return `escrow_version_regression`. Both are
  recovered by re-entering the passphrase ("Enrol with the passphrase").
- *enrolled* — keys stored and every derivable Workspace founded. No founding control is
  rendered, and the runner refuses a second founding below the UI as well.

**Three deliberate divergences from an ordinary screen.** No copy-to-clipboard for the
passphrase (a clipboard manager or cloud clipboard sync would carry the encryption ceiling
off the device — it is monospaced and selectable, to be written on paper); an explicit "I
have written this down" checkbox gating the founding button, asked *before* the run so an
interrupted ceremony still leaves the phrase in hand; and `FLAG_SECURE` on the window
while the screen is mounted, because the recents thumbnail is a real capture the system
takes unprompted. The passphrase is rendered once and leaves the widget tree on success —
the outcome's echo of it is never shown.

**Escrow conflicts arrive as `bad_escrow_signature` (403), not `escrow_version_regression`
(409).** The server verifies the record's Root signature against the `root_pk` already in
the slot before it compares versions, so a fresh device founding an already-founded
account is refused for signing with its own Root. The version conflict is only reachable
for the same Root re-writing its own slot, which the ceremony tolerates internally. Both
classify as "an escrow already exists for this account", and both reveal the passphrase
route even when the escrow probe said the slot was empty — pre-filled with the phrase this
session generated, into an empty field only. The reveal is sticky for the session and the
field keeps what the user typed, because the phrase that claimed the escrow may be another
device's and a mistyped correction must not withdraw the route or hand back the rejected
phrase.

Automated coverage:

- `app/test/sync/enrolment_ceremony_runner_test.dart` — the real runner over the real
  `SyncStack`, against `FakeSyncServer`: founding, the refusal of a second founding
  (asserting the server saw no write), an offline run leaving the device un-enrolled, both
  crash windows and their passphrase resumes, the escrow conflict, a second phone enrolling
  on the passphrase alone, and `escrowExists` distinguishing a fresh account from a founded
  one (including that it *throws* offline rather than answering `false`, which would send a
  second device into a founding the account cannot accept). **Deliberately not a
  `SimDevice` test:** a `SimDevice` hands every client the same omnipresent `DeviceLink` at
  construction, so it cannot notice a stack that fails to propagate the member transport to
  the preferences Workspace's client — the one place production diverges from the harness.
  Attaching that transport at construction instead of on every factory call makes the first
  case fail with `this device has no member credential yet`, which is exactly the bug the
  test exists for.
- `app/test/screens/enrolment/enrolment_ceremony_screen_test.dart` — the screen over a
  scripted runner: both doors, the unreachable probe, the sign-out action, and the
  `FLAG_SECURE` set/clear pair. It sets a tall viewport: a `ListView` only inflates children
  near the visible window, so on the default 800px surface the checkbox and the founding
  button would be *absent* from the tree, and a finder that missed them would read as "the
  screen offers no founding" — a claim other cases in the file make on purpose.
- `app/test/screens/enrolment/enrolment_ceremony_status_test.dart` — the state table and the
  failure classification as pure functions.
- `app/test/router_test.dart` — the gate that routes here and pins the device here
  (`needsEnrolment` forces every location to `/enrolment`; `ready`/`signedOut` bounce it
  back to `/inbox`; `checking` redirects nothing).

### Manual runbook

The ceremony's real path needs a real key store and a real server, so it only runs by hand.
Against the compose stack (`podman compose -f infra/docker-compose.yml up -d`) with an
emulator:

1. **Sign up or sign in.** The Workspace ids, the escrow slot and the Grants all derive from
   the account, so there is nothing to enrol against before authenticating — and the flow
   takes you here on its own, with no Settings entry to find.
2. Expect *Not enrolled* and **Generate passphrase** on a fresh account; expect the
   passphrase field and no founding control on a second device of an account that is
   already founded.
3. **Generate**, then confirm the checkbox, then **Found the Workspace**. Expect a few
   seconds of spinner (the Argon2id floor, on a background isolate) and then the app —
   completing the ceremony flips the session gate and the router lands you on `/inbox`.
4. **Verify server-side**: `podman compose -f infra/docker-compose.yml exec postgres psql -U jeeves -d jeeves -c "SELECT workspace_id, version FROM recovery_escrows"`
   shows two slots, and `SELECT workspace_id, author_member_id, author_seq, op_class FROM ops ORDER BY seq`
   shows two control ops per Workspace (genesis, then the root-signed owner Grant).
5. **Re-open the app.** Expect the Inbox, not the ceremony: the gate reads *enrolled* from
   the store and the redirect stops firing. Navigating to `/enrolment` by hand bounces to
   `/inbox`.
6. **Airplane mode, fresh account.** Expect the retry note rather than a founding button
   (the escrow probe cannot answer). With the probe answered and the *founding* offline,
   expect "Server unreachable", *Not enrolled* still on screen, and the generated
   passphrase still shown for the retry. The copy deliberately does **not** claim nothing
   was written: "unreachable" describes the request that failed, and a lost response to the
   escrow PUT is indistinguishable from one that never arrived — so it tells the user to
   keep the passphrase and, if a retry then reports an existing escrow, to enrol with it.
7. **Screen capture.** `adb shell screencap` on the ceremony screen returns a black frame
   while `FLAG_SECURE` is set, and a normal one on any other screen — which is also the
   check that the flag is being cleared on the way out.

**The passphrase is generated on the device, shown once, and is unrecoverable.** Write it
on paper before tapping **Found the Workspace**, and do not leave the screen until it
lands you in the app.

## The store cutover (verify on a debug install)

The first open of a build carrying #595 creates `jeeves_domain.sqlite` and **deletes**
`jeeves.sqlite` and its `-wal`/`-shm` sidecars (ADR-0035). The io-level behaviour — the
replay gate (the `jeeves_domain.rebuilt` marker, including the retry after a replay that
never completed), the deletion, its idempotence — is asserted over a temp directory in
`app/test/database/domain_store_io_test.dart`, and the op-log replay itself in
`app/test/sync/domain_rebuild_test.dart`.

On a device, the check needs the store, so it needs `run-as` and therefore a **debug or
emulator install**:

1. Install a pre-cutover build (or fabricate the file: `adb exec-out run-as loonyb.in.jeeves.dev sh -c 'echo x > app_flutter/jeeves.sqlite'`).
2. Install the cutover build and launch it.
3. `adb exec-out run-as loonyb.in.jeeves.dev ls app_flutter` — expect `jeeves_domain.sqlite`
   present and `jeeves.sqlite` (with both sidecars) gone.
4. On a device that was enrolled, expect the domain store to hold the data the op log has
   reduced; on one that never enrolled, expect it empty, which is the sanctioned state to
   re-import from.

A **release** phone cannot be checked this way at all (`run-as: package not debuggable`),
so it gets behavioural verification only: sign up → land in enrolment → found → the drawer
indicator goes green → run the Nirvana import and watch the server's op count rise.

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
  adb shell input tap 540 440    # Sign out tile
  sleep 1
  adb shell input tap 844 1378   # confirm
  sleep 2
  adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png /tmp/s.png
  ```
- Use `adb shell monkey -p loonyb.in.jeeves.dev -c android.intent.category.LAUNCHER 1` to cold-launch; prefix with `adb shell am force-stop loonyb.in.jeeves.dev` for a clean start.
- Stream Flutter errors: `adb logcat > /tmp/jeeves.log &` then grep for `flutter:` and `AndroidRuntime`. MWA failures surface as `com.solana.mobilewalletadapter.clientlib.*` stacks.

### Inspecting the on-device database

When the UI and the user's intent disagree, query the on-device database directly before reading provider/widget code — it splits persistence bugs from watcher/stream bugs in one step.

A device holds **two** stores, and which one to pull depends on the question:

| File | Holds | Ask it about |
|---|---|---|
| `app_flutter/jeeves_domain.sqlite` | the domain read model — `todos`, `actions`, `captures`, … as plain tables Drift owns | "is the row right?" |
| `app_flutter/jeeves_sync.sqlite` | the op log, the outbox, reduced fields, tombstones, integrity alarms | "did the write become an op, and did it leave?" |

```
adb exec-out run-as loonyb.in.jeeves.dev cat app_flutter/jeeves_domain.sqlite     > /tmp/jeeves_domain.sqlite
adb exec-out run-as loonyb.in.jeeves.dev cat app_flutter/jeeves_domain.sqlite-wal > /tmp/jeeves_domain.sqlite-wal
adb exec-out run-as loonyb.in.jeeves.dev cat app_flutter/jeeves_domain.sqlite-shm > /tmp/jeeves_domain.sqlite-shm
sqlite3 /tmp/jeeves_domain.sqlite "SELECT id, title, clarified, intent FROM todos LIMIT 20"
```

Pull all three files — the WAL usually holds the most recent writes. Every synced name is a real table, so query it directly. If the row is correct there, the bug is in watcher invalidation (see the live-refresh invariant in [ARCHITECTURE.md](./ARCHITECTURE.md)); if it is wrong, the bug is in the write path. To ask the second question, pull `jeeves_sync.sqlite` the same way and read `op_log`, `outbox`, `reduced_fields` and `row_tombstones`.

**`run-as` is debug-only.** A release-flavour install refuses it (`run-as: package not debuggable`), so a store on the user's production phone cannot be pulled at all. Verify store-level behaviour on a debug or emulator install; a release device gets behavioural verification only — what the UI does, and whether the server's op count moves.

### Navigation tree with tap coordinates

Coordinates are `(x, y)` in device pixels. The drawer lives under a hamburger icon on every main shell route.

| Location | Coords | Notes |
|---|---|---|
| **App shell (Inbox etc.)** → hamburger / drawer | `(105, 423)` | Top-left button below the large title header; bounds `[42,360][168,486]`. |
| **Drawer** → Settings row | `(250, 2280)` | Near bottom of drawer; wait ~1s after opening. |
| **Settings** → back arrow | `(106, 170)` | Top-left `BackButton`. |
| **Settings (signed-in)** → Sign out tile | `(540, 440)` | The only tile under SYNC when signed in. |
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
2. `tap 540 440` (Sign out tile) → dialog
3. `tap 844 1378` (red confirm)
4. Verify: still on `/settings`, SYNC section now shows the "Sign in to sync across devices" tile in place of "Sign out". The section has exactly these two states and never reports sync *state* — that is the drawer indicator's job.
