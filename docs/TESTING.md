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
- **Automation First**: Linter and analyzer pass locally before anything is pushed; the full suite passes in CI on every PR (see Test tiers below).
- **No Unverified Work**: Code is considered incomplete until it has corresponding automated tests demonstrating its correctness.

## Test tiers

Two tiers with different jobs. The hook catches the obvious break at the moment you make it; CI proves the suite.

| Tier | What runs | Where |
|---|---|---|
| **Fast** | `build_runner` (skipped when no codegen input changed), `flutter analyze`, and only the Flutter tests covering the staged changes. Backend keeps its whole `pytest` — it costs seconds. | `.githooks/pre-commit`, every commit |
| **Full** | Both suites, entire | CI, every PR — `flutter-ci.yml`, `backend-ci.yml` |

**CI is the enforcement point.** Nothing reaches `main` without a full pass, so a commit is allowed to be locally under-tested.

**Selection is by filename.** A staged `lib/foo.dart` runs `test/**/foo_test.dart`; a staged `test/**/*_test.dart` runs itself; no match runs nothing and says so. The gap is deliberate and worth knowing: editing a widely-depended-on file runs *its* test, not its dependents'. Run the full suite yourself before opening a PR when that matters — a shared DAO, a base widget, a test helper.

**Two environment overrides:**

- `JEEVES_FULL_TESTS=1` — run the whole Flutter suite in the hook anyway.
- `JEEVES_TEST_CONCURRENCY=N` — override `flutter test --concurrency`. Flutter's default is `cores - 2`; **3 is the measured optimum on the agent host**. Do not go higher — beyond it the suite gets slower *and* starts timing out tests that pass below it.

**The codegen skip is stamp-based**, and the stamp lives where a fresh worktree cannot inherit it, so a new checkout always builds. What invalidates it — including the cases a naive mtime check misses — is spelled out where the check lives, in [`.githooks/pre-commit`](../.githooks/pre-commit); the cases pinning each one are in [`test-pre-commit-hook.sh`](../.githooks/tests/test-pre-commit-hook.sh).

Why these tiers exist, and the measurements behind them: [#440](https://github.com/TMaYaD/Jeeves/issues/440).

## Stack-Specific Testing

### Frontend (Flutter)

- **Framework**: `flutter_test`.
- **E2E/Integration**: Flutter Integration Tests for on-device testing.
- **Unit/Widget**: Widget tests and standard Dart unit tests for Riverpod providers and logic.
- **A live Drift `watch()` reached from a widget test hangs the run.** Drift's `StreamQueryStore` keeps a pending timer alive, and the test binding owns the clock, so `pumpAndSettle` never settles: it spins until its 10-minute default timeout, which looks like an infinite hang rather than a failure. Two shapes to avoid:
  - *Awaiting a stream directly* (`await db.captureDao.watchInbox().first`) — the first event is never delivered and the isolate blocks so hard the per-test timeout can't fire. Read with a plain `select` instead.
  - *A widget under test subscribing to one* (a `StreamProvider` backed by `query.watch()`). Either override the provider with `Stream.value(...)` in the harness — what `clarify_card_test.dart` and `process_to_handlers_test.dart` do — or, if the surface never renders the data live, have it do a one-shot read instead of a watch. `ClarifyCard` selects between the two with `ClarifyTagSection`: `draftInputOnly` renders no tag chips and reads the hints once via `CaptureDao.tagHintsForCapture`, so `clarify_surface_parity_test.dart` deliberately leaves `captureTagHintsProvider` un-overridden — if that option ever starts watching, the file hangs instead of passing quietly.
- **Never build a `SimWorkspace`, a `StackPhone` or any other real-store harness *inside* a `testWidgets` body.** A widget-test body runs under `FakeAsync`, which owns the clock and the microtask queue but cannot advance real I/O, so the first `await` on a `NativeDatabase` round trip never returns. The test then sits, producing nothing, until the harness kills it at its 10-minute default — indistinguishable from the Drift-`watch()` hang above, and diagnosed the same slow way. Stage the scenario in `setUp` (which runs outside the fake zone) and hand the widget the result, as `test/screens/sync_health/sync_health_journey_test.dart` does — one group per scenario, because each group gets one `setUp`. Where a body genuinely has to touch the store — asserting that visiting a screen wrote nothing, say — wrap that read in `tester.runAsync`, which is the only thing that lets real async complete inside the body.
- **In an adopter's test, never `find.byKey` an `AppTitleBar` action directly.** Where a bar action renders depends on the width breakpoint (see DESIGN.md § App title bar): the same action sits in the bar on a wide surface and inside the ⋮ menu on a narrow one, so a screen test that finds it directly passes or fails by accident of the test surface size. Adopter (screen) tests go through `findBarAction(tester, key)` / `tapBarAction(tester, key)` from `test/helpers/app_title_bar_test_helpers.dart`, which look in the bar first and open the ⋮ menu when the action is not there. The exception is a test that is *specifically* asserting in-bar placement — e.g. that an action was demoted to an in-bar icon rather than overflowed — which scopes its finder to the `AppTitleBar` (`find.descendant(of: find.byType(AppTitleBar), …)`) and pins a known surface width. The component's own tests (`app_title_bar_test.dart`), which drive the surface width themselves, may assert bar internals directly. The budget arithmetic itself (`actionBudget`, `splitActions`) is pure and unit-tested without pumping a widget.
- **A test can pass on CI and time out on the agent host, and the first remedy is to do less work.** The agent host runs this suite several times slower than a dev Mac, so a test comfortable in single digits locally can sit near the budget there and fail on the one machine CI never looks at. Both offenders were fixed by shrinking the work rather than the assertion, and one came out *stricter* for it — see `convergence_test.dart`'s negative-control test and `chain_verifier_test.dart`'s release scan, each of which explains its own sizing. To find out where tests actually stand, run the suite with `--reporter json` on the target host and diff `testStart`/`testDone` times.
- **The per-test budget is 60s, set once in [`app/dart_test.yaml`](../app/dart_test.yaml), not Dart's default.** Deliberately one number for the suite rather than per-test `Timeout.factor` exceptions, which drift upward with every slower host and hide which tests are near the line — reach for the paragraph above instead. The file itself carries how the number was chosen. Neither the budget nor an exception rescues the two hang modes above: an isolate blocked on real I/O inside `FakeAsync` never lets any timeout fire.
- **Never wait for a real-async drift write with a fixed sleep.** An in-memory drift write completes on the real event loop in microseconds; a `runAsync(Future.delayed(...))` "settle" charges its full duration on every host and masks hangs. Use `settleWithRealAsync(tester)` from `test/helpers/settle.dart` (drains the real event queue via a bounded `runAsync(() => pumpEventQueue())`, then `pumpAndSettle`) — if a test ever needs more than one real-async turn, raise its `rounds` parameter rather than reinstating a sleep.
- **`tester.tap` on a `ListView` child below the fold silently does nothing.** A `ListView` builds children within its `cacheExtent` while they still sit below the viewport, so the widget is findable but a tap at its centre hit-tests empty space (only a "would not hit test" warning). Worse, a child *beyond* the cacheExtent is not built at all, so the finder returns nothing and `ensureVisible` throws `Bad state: No element`. Drag until the finder is non-empty, then `ensureVisible`, then tap — see `_scrollAndTap` in `inbox_clarify_screen_test.dart` / `clarify_card_test.dart`.
- **`tester.enterText` leaves the field focused, so a focus-loss save has not happened yet.** Surfaces that save text on focus loss — `TaskDetailScreen`, `ActiveFocusScreen`, `ClarifyCard.forOutcome` (ADR-0023) — write nothing while the user is still in the field. A test that types and immediately asserts on the row is reading the *pre-edit* value, and reads as a broken save rather than a missing trigger. Drop focus first (`FocusManager.instance.primaryFocus?.unfocus()`, then pump) — see `_loseFocus` in `clarify_card_test.dart`. Assert **before** unmounting, too: all three of those surfaces now flush a pending edit from `dispose()`, so asserting after a teardown makes a working focus-loss trigger and a broken one indistinguishable. And read the row **raw** (`db.customSelect`, or a plain `select` on the table) rather than through `TodoDao.getTodo`, whose D2 projection COALESCEs the current Action's values over the Outcome's columns and can make the assertion unfalsifiable.
- **A focused text field keeps its wizard page mounted, so "the step unmounted" assertions lie.** `EditableText` is an `AutomaticKeepAliveClientMixin` client and wants to be kept alive while it holds focus, so a `PageView` step whose field is still focused stays in the tree off-screen when the wizard advances. `find.byKey` skips off-screen widgets by default, so the step *looks* gone while its `State` — and its controllers — quietly survive: a test of anything that happens on unmount (the `ClarifyRetention` stash, a dispose-time flush) then passes with the production code deleted. Drop focus before crossing the boundary, and assert the teardown with `skipOffstage: false` — see the step-crossing retention test in `focus_session_planning_back_test.dart`.
- **`ref.read` of a provider the widget never watches returns its initial state, not the real one.** A `StreamProvider` read for the first time inside a button callback is still `AsyncLoading`, so `status.asData?.value` is null and a `?? 'unknown'` fallback fires on every run — the surface looks wired up and quietly records the wrong value. The subscription has to exist before the callback: `ref.watch` it in `build` and pass the resolved value into the handler. A test that overrides the provider with `Stream.value(...)` does *not* paper over this; it reproduces it exactly, which is how it was caught. Watching is necessary but not sufficient: read the value as `status.value`, because a provider rebuilt by one of *its* dependencies sits in `AsyncLoading` still carrying the last real value, and `asData` is null there too — reproduce that state by overriding the provider with a body that watches a throwaway provider, then invalidating it.
- **Restore `debugPrint` inside the test body, never in `addTearDown`.** To assert on what a widget logged you swap `debugPrint` for a collector, but it is a foundation debug variable and the harness runs `debugAssertAllFoundationVarsUnset` at the end of the *test body* — before any tear-down fires. Restoring via `addTearDown` therefore fails every time with "The value of a foundation debug variable was changed by the test", pointing at the test rather than at the restore. Wrap the logging window in `try`/`finally` and reassign the original there; see the refresh-error case in `async_subject_test.dart`.
- **Grepping for UI copy must be case-insensitive.** `_SectionLabel` (`plan_summary_step.dart`) renders `label.toUpperCase()`, so a widget test asserts the rendered upper-case form (`'UP NEXT (3)'`), never the source string passed in. A case-sensitive grep for the mixed-case label misses every assertion that needs updating after a rename — including `findsNothing` assertions, which then keep passing, but vacuously: the string they're checking for was never going to match the *old* label either, so the check proves nothing. `plan_summary_multi_select_test.dart` is the case this was caught in.
- **A deeply-nested worktree path can break `flutter test` before a single test runs.** The native-assets step relinks a bundled dylib with `install_name_tool`, which fails when the rewritten install name does not fit the dylib's existing header padding: `changing install names or rpaths can't be redone … larger updated load commands do not fit`. The dylib was built for a path under the repo root, so a worktree nested a few levels deeper than that overflows the padding. Deleting `app/build/native_assets` does not help — the next run rebuilds it at the same long path and fails identically. (The engine whose dylib first surfaced this is gone, but the mechanism is generic to any bundled native asset.)

  Two things make this expensive to diagnose. It reports as a *build* error, not a test failure, so the run produces no test counts at all; and piping the command through `tail` discards the non-zero exit status, so a run that executed zero tests reads as a pass. Create agent worktrees at a short path (`/tmp/<name>`), and capture exit codes explicitly (`cmd > log 2>&1; echo "exit=$?"`) rather than trusting a piped summary line.

- **Pre-commit hook and the shared FVM SDK cache**: the SDK is shared between every worktree and worker on the machine, and both its launchers (`bin/flutter`, `bin/dart`) resolve their own identity through `git`. That makes `bin/cache/flutter.version.json` a piece of *global* state that a single careless commit can wreck for everyone, so `.githooks/pre-commit` carries two distinct protections for it. Regression coverage lives in two files: `.githooks/tests/test-pre-commit-hook.sh` (fast, stub-based, four shells — the red/green detector for the hook's *logic*) and, since #678, `.githooks/tests/test-pre-commit-real-sdk.sh` (slower, against a real pinned SDK — the detector for the *SDK* changing, described at the end of this section).

  The first is *where* the self-heal runs. That step rewrites `bin/cache/flutter.version.json` before `dart run build_runner`, since a sibling worker's run can knock the file out mid-commit — and it runs `flutter --version` from *inside the resolved SDK's own directory*, never from `app/`. Flutter derives the identity it writes into that cache from the git repo of its cwd, so running it from `app/` would stamp *Jeeves's* revision into the shared cache instead of Flutter's own (`{"flutterVersion":"0.0.0-unknown","repositoryUrl":".../Jeeves.git",...}`), after which `dart pub` fails version solving machine-wide until the cache is repaired.

  Linked worktrees don't carry their own `app/.fvm/flutter_sdk` (it's gitignored and only materialized by `fvm use`), so the hook's resolution loop also checks the main checkout's — resolved via `git rev-parse --git-common-dir`, which always points at the main worktree's `.git` regardless of which worktree is running the hook. If no SDK can be resolved anywhere (local, main checkout, or the system fallback paths), the hook fails loudly with a clear message rather than silently running with no `flutter`/`dart` on `PATH`.

  The second protection is clearing git's repo-local environment, and a `cd` cannot substitute for it. When `git commit` runs the hook from a linked worktree, git exports `GIT_DIR`, `GIT_INDEX_FILE` and `GIT_PREFIX` into the hook's own environment, pointing at the committing worktree's git-dir. Those survive any `cd` — git prefers an explicit `GIT_DIR` over cwd-based discovery — and every child process inherits them, so *any* Flutter or Dart invocation resolves its revision against Jeeves rather than the SDK. `dart run build_runner` is the damaging one: `bin/internal/shared.sh` validates the tool cache against `git -C "$FLUTTER_ROOT" rev-parse HEAD`, gets Jeeves's revision, judges the cache stale, **deletes** `bin/cache/flutter.version.json` — and, unlike `flutter`, never rewrites it. One commit from one worktree then wedges every other worker on the machine (#644).

  So the hook runs `unset $(git rev-parse --local-env-vars)` **once, in its own shell, for the whole Flutter section** — above the SDK-root resolution and above every `flutter`/`dart` call, not inside any subshell or `if`. The consequence is load-bearing for future edits: **any new `git` invocation in that section must be placed above the unset line**, or it will resolve against the wrong repository. The list is deliberately git's own `--local-env-vars` rather than a blanket `GIT_*` sweep — `GIT_SSH_COMMAND` and `GIT_ASKPASS` are not repo-local and must survive for a `dart pub` fetch of a git-sourced dependency to keep its credential path.

  Obtaining that list is treated as a prerequisite, not a best-effort step: the hook fails closed when `git rev-parse --local-env-vars` exits non-zero **or** answers with nothing. A status check alone would not be enough — an empty-but-successful answer leaves a bare `unset` with no operands, a silent no-op under `sh`/`bash`/`dash` and a non-fatal error under `zsh`, so nothing is cleared and every Flutter invocation below runs with the leaked variables intact.

  If the shared cache is ever corrupted by some other means (e.g. running `flutter --version` by hand from inside `app/`), confirm the diagnosis by reading `frameworkRevision` in `bin/cache/flutter.version.json`: if it matches a *Jeeves* commit rather than a Flutter one, the SDK computed its version from this repo. Repair by running `flutter --version` from inside the SDK's own directory (e.g. `(cd ~/fvm/versions/<version> && bin/flutter --version)`), not from `app/`.

  **SDK drift vs hook drift — the real-SDK check.** The stub suite is a strong detector for the hook's *logic*: its fake `flutter`/`dart` launchers hand-model the SDK's self-resolution and go red against the unfixed hook. What they cannot notice is the *SDK* changing — if a future Flutter release resolves its own revision through a different channel, the stubs keep passing while the #644 protection quietly stops matching reality. `.githooks/tests/test-pre-commit-real-sdk.sh` closes that blind spot with one additive check: it drives the hook's Flutter path against a real, pinned, **disposable** Flutter SDK, from a real linked worktree, through a real `git commit` — the exact #644 configuration — using a minimal generated Flutter package (`build_runner` pinned to the version `app/pubspec.lock` resolves). It asserts `bin/cache/flutter.version.json` survives byte-for-byte (catching deletion *and* mutation, schema-agnostic because the real file carries no wall-clock fields) and that its `frameworkRevision` still matches the SDK's own `git rev-parse HEAD`. It fails if a future SDK stops resolving its revision through `git -C "$FLUTTER_ROOT" rev-parse HEAD` (a non-interposing `git`-shim asserts at least one such SDK-targeted call happened) or stops being a git checkout at all (asserted as a precondition — a release archive keeps its `.git` because `flutter upgrade`/`channel` need it). It does not replace the stub suite; it runs alongside it.

  **Where it runs, and why the cache is off.** In the Flutter workflow (`.github/workflows/flutter-ci.yml`, job `hook-real-sdk`), not the fast SDK-less `Infra & hooks` job in `backend-ci.yml`, because it needs a real SDK. The job runs `flutter-action` with `cache: false`: analyze/android-build cache the SDK across runs, and a *corrupted* SDK saved and restored later — the trap below cannot beat a cancelled/timed-out job's save — is precisely the hazard this check exists to catch, so it downloads a fresh disposable SDK each run and never saves it. That fresh install is **warmed** first (a clean-env `flutter --version` builds `flutter_tools.snapshot`/`.stamp`, and building the tool runs a `pub get` that touches `pubspec.lock`), so all four of `shared.sh`'s cache-invalidation conditions are satisfied before the baseline is snapshotted, leaving the revision mismatch — the #644 signal — as the only remaining invalidation. The triggering commit runs under `env -i` with an empty `HOME` (which neutralises the hook's `$HOME/*flutter` fallbacks) and `PUB_CACHE` pinned to the runner's warmed `~/.pub-cache`, because the fixtures' `pub get` ran under the real `HOME`. As a parallel job the PR wall-clock grows by `max(0, this_job − analyze_job)`, dominated by the uncached SDK download.

  **Disposable-SDK-only safety model.** The bug *deletes shared SDK state*, so a mis-designation against a shared SDK would wedge `dart pub` for every worker on the machine. The check therefore uses **only** the SDK explicitly designated via `JEEVES_REAL_SDK` (CI passes the runner-local `flutter-action` install), never auto-resolving the machine's SDK, and **hard-refuses** — refusal, not a warning — any designation that resolves to the FVM store or the hook's own shared fallbacks. The FVM store is enumerated at both default roots (`~/fvm/versions/*`, `~/.fvm/versions/*`) and at any configured cache (`$FVM_CACHE_PATH/versions/*`, and the legacy `$FVM_HOME/versions/*`), alongside `~/development/flutter`, `~/flutter`, and `/opt/flutter`. A `trap … EXIT` repairs the disposable SDK with a clean-env `flutter --version` even if a run corrupts it. It **skips loudly** (exit 0) when no disposable SDK is designated, so a developer with no throwaway SDK is not blocked, but **fails rather than skips** under `CI` (or `REQUIRE_REAL_SDK=1`, which the job sets) — a silently skipped real-SDK check is exactly how SDK drift would stay invisible. Before shipping any change here, prove the check has teeth by running it with `HOOK` pointed at a deliberately-unfixed copy of the hook against a disposable SDK: the byte-compare must go red. If a pinned SDK ever fails to corrupt against the unfixed hook, the check is green-by-construction — stop and escalate, do not ship it.

  **A recorded acceptance-criterion narrowing.** #678's criterion asks one check to assert *both* that `flutter.version.json` survives *and* that no `git rev-parse --local-env-vars` name reaches a Flutter/Dart child. The real-SDK check deliberately **splits** these. Survival is asserted here directly. The "no repo-local var reaches a launcher's own environment" clause stays the **stub suite's** job (`assert_no_local_git_env_leaked`, precisely on four shells), because the real launchers run *unmodified* and so nothing can record a launcher's own environment; the real-SDK check still catches any *harmful* leak through the survival outcome (a leak that corrupts changes the cache → the byte-compare reds), and its non-interposing `git`-shim adds the mechanism-drift sentinel above. A **liveness gate** keeps the survival assertions from being vacuous: because `pre-commit`'s `^app/` gate lets a mis-staged fixture exit 0 having never touched Flutter, the check asserts the hook's own `Flutter app files modified` and `Running build_runner` output actually appeared before trusting any survival or revision assertion.

- **Pre-commit hook and an unusable `backend/.venv`**: `backend/.venv` is gitignored and only ever materialized by `uv sync`, so a freshly created linked worktree has none — run `cd backend && uv sync --extra dev` before your first commit that touches `backend/`. Rather than sourcing the venv blind, the hook fails closed through four checks, because **existence is not activation** and each step between them is another chance to fall through to the outer `PATH`:

  1. `backend/.venv/bin/activate` **exists** (`[ -f ]`, which also rejects a broken symlink).
  2. It is **readable**. Bad mode bits abort a POSIX-mode `.` with only the shell's own error, and elsewhere are not fatal at all; checking first means every interpreter gets the same actionable message.
  3. Sourcing it **succeeded**. The hook probes this in a **subshell** (`if ! ( . .venv/bin/activate )`) rather than sourcing directly, which catches a corrupt or half-written activate.
  4. Activation actually **took effect**: `ruff`, `mypy` and `pytest` must each resolve *inside* `.venv/bin`. This is the one that matters most, because an activate truncated by an interrupted `uv sync` is still valid shell — every interpreter sources it happily and returns 0 while setting no `PATH`, so no status check of any kind can see it. Verifying the effect is also what stops the checks silently running against the wrong environment.

  Steps 2–4 all report the venv as present-but-unusable and point at `cd backend && rm -rf .venv && uv sync --extra dev`, since "run `uv sync`" alone reads as wrong advice to someone who can see the file sitting there.

  **`/bin/sh` is not the same shell on your Mac as it is in CI, and the difference is silent.** On Linux (so in CI, and for `#!/bin/sh` hooks on a Linux dev box) `/bin/sh` is **dash**; on macOS it is **bash in POSIX mode**. They disagree about what is fatal when sourcing: bash-as-sh aborts on a failed *special builtin* (an unreadable file) but recovers from a *parse error*, whereas dash dies on both — and dies before the hook can print anything, so the operator gets a bare non-zero exit with no message. That is why step 3 probes in a subshell: the subshell contains the death and turns it into a status the hook can report on, identically under every interpreter. The suite therefore runs `dash` as its own row rather than trusting `sh` to cover it; without that row a macOS run goes green on a hook that dies mute in CI. Install `dash` locally (`brew install dash`) or the row self-skips and the coverage silently disappears.

  The guard matters because the unguarded source was **interpreter-dependent, not fail-safe**. Git runs the hook through its `#!/bin/sh` shebang, and in POSIX mode (`/bin/sh`, dash) `.` is a special builtin, so a failed `. .venv/bin/activate` terminates the script: the hook did return non-zero and git did refuse the commit, but all the operator got was a raw line-number error naming no remedy. Outside POSIX mode — **`zsh`, and plain `bash`** — the same failure is non-fatal: execution falls through to the unactivated `ruff`/`mypy`/`pytest` calls, and where those resolve on the outer `PATH` they "pass" against the wrong environment and the hook reaches `exit 0`. `exit 0` is the hook telling git to proceed, so the commit *is* made — printing `✅ All pre-commit checks passed!` over checks that never ran against the venv (#539, same false-green genre as #537). Either way the operator has no actionable signal, so the prerequisite is asserted explicitly rather than left to the interpreter's `.` semantics.

  Note the shape of the original report ("exits 0 without committing"): a hook abort under `/bin/sh` blocks the commit, so an exit status of 0 observed alongside nothing committed means the *real* non-zero status was swallowed on the way out — the same piped-command trap recorded for #537 above. Capture `git commit`'s exit code directly, and confirm the commit with `git log --oneline -1` and `git status --porcelain`.

  `.githooks/tests/test-pre-commit-hook.sh` covers all four checks, and deliberately runs every backend case under **every shell present — `sh`, `dash`, `bash`, and `zsh`**. `sh` is the production path and pins the POSIX-mode abort; `dash` pins the stricter Linux/CI fatality described above; `bash` and `zsh` pin the fall-through that reaches `exit 0`, which an `sh`-only suite would have gone green on. (`sh` and `bash` are distinct runs even where `/bin/sh` *is* bash, since POSIX mode is what makes the failed source fatal.)

  Two things about that suite are load-bearing and easy to undo by accident. First, the unusable-venv cases pass **`OUTER_TOOLS` on `PATH`** — that, and not the stubs inside `.venv/bin`, is what makes a false green reachable at all: a failed or inert activation never puts `.venv/bin` on `PATH`, so the outer stubs are the only tools a fell-through hook can find, and without them it would die on a missing binary and "pass" for the wrong reason. Second, each case asserts the **phrase unique to the guard it targets**, because all four exit non-zero and name both `backend/.venv` and the remedy: without the phrase they are indistinguishable, and deleting the existence check entirely would still leave the suite green (the readability check catches a missing file too, while misreporting that it "exists").

- **`prepare-commit-msg` and the issue reference it appends**: the number is extracted by **anchored** POSIX parameter expansion, never by scanning the branch name for digits, and what reaches the message is always **bare digits** — `(#123)`, never `(#JVS-123)` or `(#review-655)`. The accepted shapes are `<type>/<number>[-<slug>]`, `issue-<number>/<slug>`, `JVS-<number>[-<slug>]`, and a bare `<number>[-<slug>]`; anything else appends nothing, silently and with exit 0. Three rules in there look removable and are not: **a leading zero disqualifies** (this repo's migration and ADR numbers always carry one, GitHub issue numbers never do, so `fix/0028-ambiguous-parameter` must not become `#28` — note that `fix/alembic-0028-…` is stopped one step earlier, by the anchor, so it is not evidence for this rule), the `issue-*/*` branch of the `case` **must stay above** the `*/*` branch (swap them and `issue-458/…` silently yields nothing), and the **trailing-number shape is deliberately unsupported** (`feat/login-ui-94`), because the tail of a branch name is where versions, ADR numbers and dependabot bumps live. The accepted cost is that ad-hoc working branches (`review-655`, `addr-595`) now append nothing where they sometimes appended the right thing; the remedy is conventional branch naming, and the trade is deliberate — a false positive is permanent tracker pollution, a false negative is silent and harmless. Two residuals are known and unguarded: `chore/2026-08-audit` would append `(#2026)`, and `git commit -m 'feat: x' -m '#605'` appends a second reference — on the plain `-m` path git cleans up with `whitespace`, which **keeps** comment lines, while the hook strips them. That is a cleanup-**mode** mismatch, not a comment-character one: it behaves identically under `#`, `core.commentChar` and `core.commentString`.

  The already-referenced guard matches the reference **as a token** — `#<number>` followed by a non-digit or end of line — not as a substring. The old substring test found `605` inside `1605` and skipped the append entirely, and with the degenerate id `0` that a generated worktree branch used to produce, it matched almost any message.

  **The hook runs before the editor, so it must not write into an empty message.** On the editor path (`$COMMIT_SOURCE` empty — a plain `git commit`) git has not opened the editor yet: the file holds only the comment block, and line 1 is blank. Appending there fills a file git would otherwise treat as empty, so **quitting the editor without saving records a commit whose subject is `" (#605)"` — leading space and all — instead of aborting** — the standard quit-to-cancel gesture, silently broken. The hook therefore appends only when `$COMMIT_SOURCE` is `message`, which means the editor path never receives a reference at all.

  **That guard is a test on `$COMMIT_SOURCE`, not a look at the file, and the difference is the whole point.** An "is the message empty yet?" heuristic has to tell git's comment block apart from message text, so it has to know the comment character — and `core.commentChar` / `core.commentString` are documented settings that change it. Keyed on a hard-coded `^#`, such a heuristic reads git's own template as a subject the moment either is set, and the abort **fails open**: `core.commentChar=';'` and `core.commentString='//'` each turn a cancelled commit into a recorded one with the subject `" (#605)"`. So the dependency runs the opposite way to how it first looks — it is the **omission** of comment-character awareness that endangers the abort, not the cost of adding it. Testing `$COMMIT_SOURCE` retires the dependency outright instead of trying to parse around it. The suite pins the abort across the full **six-cell matrix** — {default, `core.commentChar=';'`, `core.commentString='//'`} × {`commit.verbose` on, off} — asserting zero commits recorded in every cell, not just a non-zero exit status.

  **`--fixup`/`--squash` subjects are git's own, and the hook leaves them byte-identical.** `git commit --fixup <sha>`, `--squash <sha>`, `--fixup=amend:<sha>` and `--fixup=reword:<sha>` all arrive with `$COMMIT_SOURCE=message` — the same value a plain `-m` produces — so the `$COMMIT_SOURCE` guard lets them through. But git has already built these subjects as `fixup! <target>` / `squash! <target>` / `amend! <target>` (both `amend:` and `reword:` emit `amend!`), and `git rebase --autosquash` matches them against the target's subject **byte-for-byte**; appending `(#NNN)` breaks that match, so the fixup never squashes and survives the rebase as a standalone commit (#675). The hook therefore additionally leaves any subject whose first line begins `fixup! `, `squash! ` or `amend! ` verbatim — exactly the prefixes git's own autosquash recognises. `$COMMIT_SOURCE` cannot tell these apart from `-m` (a *hand-typed* `fixup!` subject is indistinguishable from a generated one), so the subject prefix is the only signal, and matching only these three git-authored prefixes means a non-match costs nothing. The suite pins this with a **real `git commit --fixup`/`--squash` and a real `git rebase --autosquash`**, and builds the fixup **target reference-free on `main`** before checking out the numbered branch — were the target built on the numbered branch it would already carry `(#605)`, and the already-referenced guard would suppress the append even on the *unpatched* hook, so the case would pass against the bug and prove nothing. That is the exact invisibility the issue names: the defect hides whenever the target already carries the reference. Beyond the byte-identical subject, the case asserts the fixup **collapses into its target** — the commit count drops by one and no `fixup!`/`squash!` subject survives the rebase.

  The already-referenced guard still reads the message through a helper that drops comment lines **and everything from the scissors line down**: on the `-m … -e` path git appends its status block and, under `commit.verbose`, the staged diff below the scissors un-commented, so without the trim a `#605` inside the diff counts as an existing reference and suppresses a legitimate append. That trim matches on the **`---- >8 ----` run alone, never on the comment prefix in front of it**, so it needs to know nothing about the comment character and holds under `#`, `core.commentChar`, `core.commentString` and `core.commentChar=auto` alike. The suite pins the trim under `commentChar` and `commentString` as well as the default.

  **Comment lines are dropped by `git stripspace --strip-comments`, not by a hard-coded `^#`.** That is git's own plumbing for the job: run in the repository, it reads `core.commentChar` / `core.commentString` itself, so nothing is interpolated into a pattern and no prefix has to be escaped — a hand-rolled `grep -v "^$prefix"` would need both, since git's candidate list contains `$`, which raw in a BRE is the end-of-line anchor and would silently strip every blank line. The defect this closes needs no unusual message, only an unusual config: under `core.commentChar=';'` on a branch named `fix/605-#605`, git's own status line `; On branch fix/605-#605` sails through a `^#` filter, and the guard reads the `#605` in **git's** text as an existing reference and silently suppresses a legitimate append. The suite pins that case, its default-comment-character twin, and the mirror image (a `#605` line the user wrote is real message text under `core.commentChar=';'`, so the append must be suppressed).

  Two properties of that helper are deliberate. `core.commentChar=auto` is **not** resolved — `stripspace` falls back to the default `#` rather than running git-commit's per-message candidate scan, so under `auto` the helper can disagree with the character `git commit` actually chose (measured on git 2.55: `-m '#605 subject' -e` makes git write its block with `;` while `stripspace` strips the `#` line). That is exactly what the old hard-coded `^#` did — no better, no worse — and the only exact fix is reimplementing the candidate scan. And if `stripspace` exits non-zero the helper yields **no text**, so the guard finds no reference and the append proceeds: it feeds only the already-referenced guard, never the message that gets written, so its worst case is a visible duplicate `(#605)` rather than the silently-missing reference #666 was filed for.

  `.githooks/tests/test-prepare-commit-msg-hook.sh` covers every shape above through a **real `git commit`** in a throwaway repo, with `core.hooksPath` pointed at a directory holding only this hook (the real `.githooks` would drag in `pre-commit`'s whole gauntlet). Going through git is what makes `$COMMIT_SOURCE` real, and every assertion is on the message git recorded (`git log -1`), never on hook stdout — a hook that exits 0 having done nothing and one that exits 0 having done the right thing are indistinguishable by status. Exit 0 is asserted on every case, since "appends nothing" has to be silent *and* successful. The editor cases drive a scripted **`GIT_EDITOR`** — one that quits without writing, one that types a subject — because that is the only way to reach `$COMMIT_SOURCE=""`; the quit case asserts on the **commit count**, not just the exit status, since a hook that fabricates a message makes git succeed. The autosquash cases (#675) go one step further than the subject assertion: they drive a real `git rebase --autosquash` and assert the fixup collapses — the commit count drops and no `fixup!`/`squash!` subject survives. Like the pre-commit suite, it runs each case under **`sh`, `dash`, `bash` and `zsh`** by rewriting the copied hook's shebang; `dash` is not redundant with `sh`, because CI's `/bin/sh` is dash while macOS's is bash in POSIX mode.

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
- `convergence_test.dart` — enrolment, both-directions convergence, tombstones, offline queue and reconnect, replay idempotence, field-grain merge, the fail-closed quarantine surface, the reducer guards, author-side wire validation (a payload no receiver could apply is refused at `capture()`/`captureControl()` with the store, outbox and author chain untouched), and the trust cases: a poisoned registry, a fabricated MemberRegister, a genuine certificate wrapped around a forged envelope, and a zero chain link into a populated chain — each end to end through the spine. It also carries the cross-device half of scope attribution: two un-awaited `capturing` calls on one device, one rolling back, and the peer holding only the write that committed — the phantom a misattributed write produces reaches its own author first, because the op it should never have signed is reduced and projected back into the store the rollback emptied.
- `grants_and_genesis_test.dart` — #549's acceptance criteria end to end: `workspace_genesis` and the log-state rule that decides who founds, Grants and the `(role, op_class)` matrix, grant-granular revocation, and the `epoch_floor` (raise-only, survives restart, and — the case a floor must not become — a raise that does not brick its own author's content writes). Every assertion is about what a *client* concludes, because the server's `workspaces` and `grants` tables are authoritative for nobody.
- `e2ee_test.dart` — #554's acceptance criteria end to end: turn-on (every content op after it is `aead_v1` and no marker byte survives on the wire, while the pre-turn-on history stays plaintext and stays readable), a fresh device converging on the passphrase alone through the escrow wraps, the two encryption *alarms*, revoke-plus-rotate, the ceremony that refuses before authoring, the scheduled-rotation trigger, and a Workspace keyed at genesis. Two of its cases look like duplicates and are not: a **tampered ciphertext** is `signature_invalid`, because the signature covers `header ‖ body` and the order is verify-then-decrypt, so an `aead_failure` needs an author that really signed bytes that do not open. No test hands an epoch key from one device to another, exactly as none hands one a Root.
- `control_fork_test.dart` — two control ops naming one predecessor. The tie-break (earliest *certificate* HLC, then lowest author member id), the losing branch quarantined along with everything chaining through it, and the rebuild that follows because a resolved fork can change which content ops were authorized.
- `chain_verifier_test.dart` — the per-author chain rules as rules: gap, replay, fork, the idempotent re-serve, and the `(workspace, author, author_seq)` uniqueness constraint that backs the slot-collision verdict.
- `chain_integrity_test.dart` — the own-writes comparison and the integrity alarms it raises: a server that rolled our writes back, a substituted copy of our own op, and a server ahead of everything we authored.
- `enrolment_test.dart` / `recovery_escrow_test.dart` / `passphrase_policy_test.dart` — the ceremony's own edges (passphrase change, rollback and substitution *alarms*, below-floor blobs), the blob codec against real Argon2id and XChaCha20-Poly1305, and the entropy estimates behind the passphrase warning.
- `dao_capture_contract_test.dart` — one assertion per DAO write path: which ops it authors, on which entities, with which fields. This is the contract the flip rests on — a path that never described its effect is a write that silently does not sync — so a write path without a capture assertion is a test gap by construction. It also pins the two deliberate asymmetries: `deleteOutcome`'s enumerated cascade set, and the absence of the dead cache. And it pins the negative half of the same contract — an absent Outcome authors *nothing*, including when a junction row survives it — since a write path can be wrong by describing an effect it did not have as easily as by describing none. Its `the seam itself` group is the seam's own contract rather than any one DAO's: the transaction boundary, nesting and coalescing, and **attribution under overlapping writers** — two un-awaited `capturing` calls, with each op asserted against the *commit that flushed it* (a `_CommitLabellingCapture` labels them, since emission order alone cannot tell "each scope emitted its own" from "one scope emitted both"), and the overlap itself asserted so a case cannot pass by never having overlapped. Both failure directions are pinned there through the real DAOs — a rolled-back write signed under the other scope's commit, and a committed row whose op the other scope's rollback discarded — along with the refusals that replace any silent drop: a described effect with no live scope, one in a closed scope, and one inside `uncapturedTransaction`'s mask. **When one of two overlapping `capturing` calls is expected to throw, attach its `expectLater` before awaiting the other**: the rejection can land while the sibling is still in flight, and an unobserved one surfaces as an unhandled async error instead of as the assertion.
- `workspace_routing_capture_test.dart` — the production capture binding: where an op goes and when none is authored, asserted by reading the **outbox** rather than a spy, since the `workspace_id` a queued envelope carries is the whole claim. It is also the home of the op-*loss* case, for the same reason: a committed domain row whose op an overlapping scope's rollback discarded leaves nothing for a recording double to record — only a missing envelope in a real queue.
- `collection_round_trip_test.dart` — every collection, DAO write on A → reduce and project on B → the same row, column for column. Plus the dangling-reference cases: a TimeLog outliving its hard-deleted Outcome, a junction arriving before its parent.
- `merge_strategy_test.dart` — the ADR-0030 laws as laws (commutative, associative, idempotent), not as outcomes. A strategy that passes every vector and fails a law here is one refactor from breaking convergence.
- `projector_view_notify_test.dart` — view-notify for the projector, per collection group, over the production store topology: a real on-disk sqlite_async database whose synced names are the real tables Drift created. The projector writes through `customStatement` with no `updates:` set, so the notify is what a watcher reading across a collection group depends on.
- `domain_rebuild_test.dart` — a fresh domain store rebuilt from a real device's op log: reduced state lands, a tombstoned entity does not come back, an empty log leaves an empty store, and a second run produces the same rows. It also covers the replay tail as a *reconcile* site: a log holding two same-`(name, type)` Tag entities rebuilds into two rows and then folds, and the second rebuild is still a no-op with the reconciler in the loop.
- `tag_convergence_test.dart` — two devices creating the same Tag name offline, end to end. Both reach the **same** state (same surviving id, both assignments on it, both unrelated Outcomes present, reduced state byte-equal), asserted in **both arrival orders** as identical between the two runs rather than merely internally consistent on each. `MIN(id)` must beat reference count — the ranking that would make two concurrent folds tombstone each other's survivor and kill both Tags — a tag hint on the loser must follow the fold into `capture_tags`, and a further sync must author no ops and change no rows. The three-device case is the rehome pass's reason to exist: with `X < Y < Z`, device A folds `Z→Y`, drops offline before pushing, and while offline tags a new Outcome with the tag it believes is live, while B and C fold `Y→X`. That junction is an entity **no other device ever authored**, so nothing tombstones it, and it arrives asserting a tag that is long gone with the group at `COUNT = 1`. **When changing either pass, verify by disabling it and watching this test fail** — the fold alone converges more of the three-device scenario than it looks like it should, because the repointed junctions carry derived ids and a peer passing through the same intermediate state authors and tombstones the same entity.
- `domain_reconciler_test.dart` — the two passes at unit grain, on the real Drift schema against a recording capture seam: that the schema now represents a duplicate pair at all, the fold's ranking and its idempotence, the **exact op set** it authors (the half that carries the decision to peers, which cross-device row equality cannot see), and the rehome pass's four outcomes — repoint `todo_tags`, repoint `capture_tags`, leave a junction alone when the pair is unrecoverable, and leave it alone when no live tag holds the pair.
- `providers/domain_store_rebuild_gate_test.dart` — the forced re-projection that repairs a device already holding a hole, over a real on-disk store and a real op log. The trap it pins is that the naive gate is silently inert: `databaseProvider` wraps the executor in `DatabaseConnection.delayed`, so the migration runs on the first *query*, not at construction, and nothing read off the database object beforehand knows an upgrade is coming. Hence the throwaway `SELECT 1` and the await on `GtdDatabase.opened` — a future fed from `beforeOpen`, which drift runs on **every** open, so a launch that migrates nothing resolves it instead of hanging.
- `full_day_convergence_test.dart` — capture → clarify → plan → focus (with an offline window) → preference races → evening shutdown, across two devices, then: A ≡ B on canonical bytes; a fresh device C reaching the same bytes by replay from zero; A rewinding its cursor and re-pulling unchanged; the whole log reduced in reverse order to the same bytes; and every domain table equal across all three as full rows.
- `sync_health_test.dart` — the `SyncHealth` stream from a real client and the indicator widget over fake streams.
- `rotation_resume_test.dart` — a rotation stranded between its flush and its publish, and everything the resume may then do about it, always through the production seams (`StackPhone` plus a real `SignalListener`, never the resume hook called directly). The healing cases (#617): resume on launch, resume from the pull tail, the committed-but-unacked set re-learned by the pull, and the byte-identical re-PUT the ceremony ordering forces. The refusal cases (#627): `keywrap_digest_mismatch` alarms once and terminalises, so four pulls issue **one** resume PUT rather than four; the record's bytes stay in `read` while `readResumable` stops handing them back; an unclassified code is bounded per process, alarmed, persists nothing, and gets a fresh budget on relaunch; a 500 stays a plain retry; a permanently refused *flush* raises `own_write_refused_permanently` and blames no record, while the publish is still attempted and `rotate_not_materialised` does **not** delete anything behind an undrained outbox. Faults are injected as real components: a scripted refusal on the member transport, a `PendingRotationStore` decorator whose writes throw (the keychain-hiccup case), and — for the alarm-write-fails case — the `integrity_alarms` table genuinely renamed out from under the writer. One quirk is load-bearing: a test counting resume passes drives the listener over a **quiet** signal socket, because a real subscribe's initial poke *is* a poke and queues a second sync behind the first, doubling every count.
- `rotation_resume_refusal_test.dart` — the refusal table as a table, pure, over both surfaces: every keywraps verdict, the ops verdicts, every transient status, and the property the module exists for — an unknown code is bounded on both surfaces, because there is no `default: retry`. One case reaches for the real `HttpSyncTransport` over a canned adapter: FastAPI's `RequestValidationError` sends a **list** `detail`, so the production parser yields a null code, and that shape is exercised rather than described.
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

## Enrolment ceremony

Opt-in, and **nothing routes here** (`app/lib/screens/enrolment/`, route `/enrolment`).
A signed-in, un-enrolled device runs the app normally; the user opens the ceremony from
Settings' "Set up sync on this device", and the app bar's back arrow is a real way out.
Tests that assert the absence of a redirect live in `test/router_test.dart` (the rule) and
`test/sync/offline_relaunch_session_test.dart` (the rule over a real store that genuinely
reads `notEnrolled`, which is the combination #673 was missed for). It runs
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
- `app/test/router_test.dart` — that **nothing routes the user here**.
  `signedInNotEnrolled` and `checking` redirect nothing at all, so a signed-in un-enrolled
  device uses the app normally; `ready` and `signedOut` bounce `/enrolment` back to
  `/inbox`, the router's only remaining move and a negative one. A case that asserted a
  redirect *into* `/enrolment` would be pinning the trap this ADR removed.
- `app/test/screens/settings/sync_section_test.dart` — the "Set up sync on this device"
  tile. With no redirect, this tile is the only way sync can ever start, so its absence
  would make enrolment unreachable rather than merely awkward; the test must fail if it is
  deleted.
- `app/test/sync/offline_relaunch_session_test.dart` — a signed-in, genuinely un-enrolled
  device over a stack that assembles for real, unverified and verified, offline: the user
  reaches the app, and deliberate navigation to the ceremony still works. `runAsync` is
  load-bearing — the launch waits on real Dio/SQLite/KDF timers that fake time never fires.

**The blind spot these close, and the setup that caused it.** The enrolment-routing failure shipped
because the state it depended on was one the tests could not produce: every case covering
an unverified session ran *without* a sync stack, so the enrolment read could not reach a
store, failed open, and reported an enrolled-looking answer. The combination that mattered
— unverified session over a store that genuinely says "not enrolled" — was therefore never
exercised, and the arm looked covered while being untested.

Two standing requirements follow, and neither may be dropped while enrolment stays opt-in:

- **A session-layer test that omits the sync stack is not evidence about enrolment.** In
  those tests a `ready` means "unreadable", not "enrolled". Any case making a claim about
  enrolment behaviour has to assemble a stack that actually answers, as
  `offline_relaunch_session_test.dart` does.
- **The entry points are pinned by test, because they are the only way sync can start.**
  With nothing routing the user in, deleting the Settings tile does not make enrolment
  awkward — it makes it impossible. `sync_section_test.dart` must fail if the tile goes.

### Manual runbook

The ceremony's real path needs a real key store and a real server, so it only runs by hand.
Against the compose stack (`podman compose -f infra/docker-compose.yml up -d`) with an
emulator:

1. **Sign up or sign in, then open the ceremony yourself.** Authenticating lands you in the
   app, not here: nothing routes you to enrolment. The Workspace ids, the escrow
   slot and the Grants all derive from the account, so there is nothing to enrol against
   before authenticating — but taking the next step is your move. Go to **Settings → SYNC →
   Set up sync on this device**. Check the app bar's back arrow works: it is pushed, so
   backing out returns you to Settings with the device still un-enrolled and still usable.
2. Expect *Not enrolled* and **Generate passphrase** on a fresh account; expect the
   passphrase field and no founding control on a second device of an account that is
   already founded.
3. **Generate**, then confirm the checkbox, then **Found the Workspace**. Expect a few
   seconds of spinner (the Argon2id floor, on a background isolate) and then the app —
   completing the ceremony flips the session gate and the router lands you on `/inbox`.
4. **Verify server-side**: `podman compose -f infra/docker-compose.yml exec postgres psql -U jeeves -d jeeves -c "SELECT workspace_id, version FROM recovery_escrows"`
   shows two slots, and `SELECT workspace_id, author_member_id, author_seq, op_class FROM ops ORDER BY seq`
   shows two control ops per Workspace (genesis, then the root-signed owner Grant).
5. **Re-open the app.** Expect the Inbox. Navigating to `/enrolment` by hand bounces to
   `/inbox`: the gate reads *enrolled*, and there is nothing left for the ceremony to do.
6. **Relaunch signed in but un-enrolled, with no network** — the regression that made
   enrolment opt-in. Sign in, back out of the ceremony without founding, kill the app, turn on
   airplane mode, relaunch. Expect the **Inbox**, working, with the Settings tile still
   offering enrolment. Landing in the ceremony is the bug: it needs the network the device
   has just failed to reach, and offers no way back to the user's own data.
7. **Airplane mode, fresh account.** Expect the retry note rather than a founding button
   (the escrow probe cannot answer). With the probe answered and the *founding* offline,
   expect "Server unreachable", *Not enrolled* still on screen, and the generated
   passphrase still shown for the retry. The copy deliberately does **not** claim nothing
   was written: "unreachable" describes the request that failed, and a lost response to the
   escrow PUT is indistinguishable from one that never arrived — so it tells the user to
   keep the passphrase and, if a retry then reports an existing escrow, to enrol with it.
8. **Screen capture.** `adb shell screencap` on the ceremony screen returns a black frame
   while `FLAG_SECURE` is set, and a normal one on any other screen — which is also the
   check that the flag is being cleared on the way out.

**The passphrase is generated on the device, shown once, and is unrecoverable.** Write it
on paper before tapping **Found the Workspace**, and do not leave the screen until it
lands you in the app.

## The store cutover (verify on a debug install)

The first open of a build carrying #595 creates `jeeves_domain.sqlite`. It
**deletes nothing**: the predecessor `jeeves.sqlite` and its `-wal`/`-shm` sidecars are left
in place (#673). The io-level behaviour — the replay gate (the `jeeves_domain.rebuilt`
marker, including the retry after a replay that never completed) and the fact that the open
touches no file it did not create — is asserted over a temp directory in
`app/test/database/domain_store_io_test.dart`, and the op-log replay itself in
`app/test/sync/domain_rebuild_test.dart`.

On a device, the check needs the store, so it needs `run-as` and therefore a **debug or
emulator install**:

1. Install a pre-cutover build (or fabricate the file: `adb exec-out run-as loonyb.in.jeeves.dev sh -c 'echo x > app_flutter/jeeves.sqlite'`).
2. Install the cutover build and launch it.
3. `adb exec-out run-as loonyb.in.jeeves.dev ls app_flutter` — expect `jeeves_domain.sqlite`
   present **and `jeeves.sqlite` still there, untouched**. Its disappearance is the failure:
   the app must not unlink a file it did not create, and on desktop targets this directory
   is the user's own Documents folder.
4. Check the new store's contents, and **do not read "un-enrolled" as "has no data"** —
   that premise is the one this whole issue exists to unlearn:
   - **Enrolled:** expect the domain store to hold the data the op log has reduced. The log
     is the record and the store is its projection.
   - **Never enrolled, and nothing entered locally yet:** expect it empty. This is the only
     case where empty is the pass. It is a **steady state**, not a staging post — the
     device keeps working local-only, and enrolment is offered in Settings rather than
     required.
   - **Never enrolled, but carrying local work:** expect that work to **still be there and
     still usable**. A local-only device is a fully functional GTD store; it authors no ops
     because there is nowhere to author them, which says nothing about whether it holds
     data. An empty store here is a **failure**, not the expected result.

   The one loss is at the cutover instant and is bounded to it: a never-enrolled device's
   *pre-cutover* rows lived in `jeeves.sqlite`, which the new build does not read, so they
   are not carried into `jeeves_domain.sqlite` (sanctioned once and deliberately).
   Everything entered after that launch lives in the new store and stays. If the user later
   enrols, the initial upload carries whatever is in it onto the op log (ADR-0034) — so
   local-only work is never a reason to delay enrolling, and enrolling is never a reason to
   expect a fresh start.

A **release** phone cannot be checked this way at all (`run-as: package not debuggable`),
so it gets behavioural verification only: sign up → land in the **app** → open enrolment
from Settings → found → the drawer indicator goes green → run the Nirvana import and watch
the server's op count rise. Signing up landing you anywhere but the app is itself the
failure.

The op count now covers **every** imported entity — Outcomes, Captures, Tags and both
junction tables — not just the Tags, so the expected rise is roughly three ops per imported
task rather than one per distinct tag. It rises in **steps, once per batch** of
`nirvanaImportTaskBatchSize` tasks (`app/lib/import/nirvana_local_import.dart`), because a
batch is the transaction and the op-authoring unit; a single burst at the end would mean the
batching is not doing its job. A count that stops rising mid-import is a *partial* import, and
re-running the same export completes it — the ids are deterministic, so nothing duplicates.

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
