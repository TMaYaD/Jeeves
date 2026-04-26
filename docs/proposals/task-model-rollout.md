# Task model rollout — decompose TMaYaD/Jeeves#185 into reviewable PRs

> **Status:** rollout plan for the proposal in
> `docs/proposals/task-model.md`. Companion document: read the proposal for
> *what* the new model is and *why*; read this document for *how* it lands
> in the repo, in what order, and with what per-PR scope.
>
> **Date:** 2026-04-26.
> **Tracking issue:** TMaYaD/Jeeves#185 (parent / load-bearing).

## Context

`docs/proposals/task-model.md` argues the global Task FSM (9 states + half a dozen orthogonal flags) is the wrong abstraction and proposes orthogonal decomposition: `Task { clarified, intent ∈ {next, maybe, trash}, done_at, blockers }` plus a first-class `FocusSession` entity, plus a `TimeLog` table replacing the imperative `time_spent_minutes` accumulation. Issue TMaYaD/Jeeves#185 is the load-bearing change.

The naive way to ship #185 is one XXL PR that swaps the FSM, introduces FocusSession, retires `selected_for_today`/`in_progress_since`/`time_spent_minutes`, deletes ritual-bypass DAO methods, and rewrites the planning ritual UI. That's ~42 files, ~10 heavily FSM-coupled test files, and unreviewable in one pass.

This plan breaks the work into a sequence of full-stack atomic PRs that land **one behind the other** (not in parallel). Each PR is a vertical slice — schema, DAO, UI, tests for one concept — reviewable on its own and individually revertable. The `state` column retires incrementally: each strip-PR merges one of its values into `next_action`, shrinks the CHECK constraint, and removes the now-dead UI/DAO/test surface for that state. The column itself drops in the final cleanup PR, when only `next_action` is left. FocusSession lands in a single load-bearing PR that also retires `selected_for_today` and `state = 'in_progress'` — no flag-switching, no dual-write bookkeeping.

The app is in alpha, so:
- Eager data migration (no lazy-on-read shenanigans).
- No feature flags, no FSM-and-FocusSession coexistence period at the release level.
- Backwards-compat shims, deprecated-column shadows, etc., are explicitly **out of scope** — the codebase moves forward in lockstep.

## Decisions locked in this session

These resolve enough of `docs/proposals/task-model.md` §8 to start cutting code. The rest of §8 stays open and can be settled later. The same decisions are mirrored into the proposal in §4.5, §6, §7.1, §7.2, §8 (as resolved questions), and §9.1.

1. **Each PR is a full-stack atomic vertical slice.** Schema, DAO, UI, tests all move together for one concept per PR. Keeps changes reviewable, testable end-to-end at each step, and trivially revertable.

2. **PRs land sequentially, not in parallel.** Tracking and review are easier when changes go in one behind the other than when several feature branches diverge from main.

3. **One-shot is a *release* concern, not a *column* concern.** No feature flags, no dual-version code, no FSM-and-FocusSession coexisting behind a switch. But the `state` column itself gets stripped one allowed value at a time across multiple PRs. Each strip merges that state's rows into another (typically `next_action`), shrinks the CHECK constraint, and removes the now-dead UI/DAO/test surface. The `state` column itself drops only in the final cleanup PR, when `next_action` is the only remaining value.

4. **No dual-write bookkeeping.** When FocusSession is introduced, it becomes the source of truth for "what is the focused task" and "which tasks are on today's plan." The retirement of `selected_for_today` / `state = 'in_progress'` happens in the same PR, not behind a flag. The other FSM states (`waiting_for`, `someday_maybe`, `inbox`, `done`) keep working as today, on the same `state` column, until their own strip-PRs come around.

5. **Blockers stripped, not modeled.** The polymorphic blockers epic (TMaYaD/Jeeves#181) is **not** a prerequisite. Specifically:
   - `state = 'scheduled'` collapses to `state = 'next_action'` with `due_date` retained. Investigation confirmed `scheduled` is half-baked: UI/screen/DAO/FSM plumbing exists, but no auto-transition on the day, and `ScheduledReviewStep` doesn't even consult `scheduledDueTodayProvider`. The state is decorative, not behavioral.
   - `state = 'blocked'` collapses to `state = 'next_action'`, `blocked_by_todo_id` column dropped, cascade-unblock side effect deleted. Lossy on the dependency hint, acceptable in alpha.
   - `state = 'waiting_for'` collapses to `state = 'next_action'`. The existing `waiting_for` text column on `todos` is kept as-is (no rename). The "Waiting For" list re-sources from `WHERE waiting_for IS NOT NULL`.
   - `state = 'deferred'` collapses to `state = 'next_action'`. Per proposal §4.5, `deferred` evaporates — there is no replacement.

6. **TimeLog (TMaYaD/Jeeves#182) ships without `focus_session_id`.** Adding the column on day one risks pulling FocusSession scope into the TimeLog PR. The column gets added later, in the FocusSession PR, via its own migration. TimeLog rows written before FocusSession exists simply have no session attribution; that's fine — the column is not load-bearing.

7. **TimeLog row = one contiguous task-focus span.** Switching focus from task A → B → A writes three TimeLog rows. Pauses are client-side cosmetic (per existing `focus_session_provider.dart:111-125` pattern) and do **not** split rows — breaks count as work. Pomodoro sprints are orthogonal: they do not write TimeLog rows. This kills the existing `_logSprintTimeToTask` write path at `app/lib/providers/sprint_timer_provider.dart:612-632` in the TimeLog PR (otherwise we'd double-count).

8. **FocusSession PK shape.** `id UUID PK` plus a partial unique index `(user_id) WHERE ended_at IS NULL`. Many sessions per user over time, exactly one open at any moment. Multiple task spans per session, multiple sessions per day allowed.

9. **PR TMaYaD/Jeeves#140 (Evening Shutdown) held.** Salvage-or-rewrite decision deferred until the FocusSession PR is sufficiently advanced. The session-review wrap-up flow is the final follow-up PR; #140 may be lifted into it or dropped in favor of a clean rewrite at that point.

10. **Proposal §6 framing revised.** `Timer.intervals: List<{start, end}>` was misleading. Per decision 7, a TimeLog row IS a (start, end) pair scoped to one task; a FocusSession's "intervals" are just its TimeLog rows. The list-of-intervals-per-task framing implied splitting on pause, which we're now ruling out. The proposal's §6 has been updated to match.

11. **`completed_at` is renamed to `done_at`, not parallel-added.** PR G performs `ALTER TABLE todos RENAME COLUMN completed_at TO done_at` rather than adding a new column and backfilling from the old one. Same semantics (non-null means done; value is when), one less column to ever drop later.

12. **TimeLog has zero historical backfill.** When PR D ships, `time_spent_minutes` continues to be the source of truth for pre-existing time. New time gets logged via TimeLog and updates the cache. The cache may be inconsistent for tasks that had pre-existing time AND get new TimeLog entries; that's acceptable — `time_spent_minutes` is treated as a cache that can be invalidated freely. Instrumentation/metrics get added later to decide whether to drop the cache and switch to live `SUM(TimeLog)` reads.

13. **`Intent` enum is 3-value from day one.** PR E lands `{next, maybe, trash}` at the column level. UI surfaces only `next` and `maybe` for now. The `trash` UX is a separate design.

14. **PR I's UI scope is "wire, don't rewrite."** The existing planning ritual screens (`planning_ritual_screen.dart` and steps) get wired to call `FocusSessionDao.openSession` instead of `selectForToday`. The focus screen reads `focus_session.current_task_id` instead of `state == 'in_progress'`. **The new ritual design from TMaYaD/Jeeves#180 is out of scope for PR I** — it lands in follow-up PRs after #180. If implemented right, PR I's removed LoC exceeds added LoC.

## PR sequence

The full sequence, in landing order:

```
A.  Strip `scheduled` state                     (cleanup, dead-ish code)
B.  Strip `blocked` state + blockers            (cleanup)
C.  Strip `deferred` state                      (cleanup; it evaporates)
D.  TimeLog (#182), no focus_session_id         (additive, replaces time-spent accumulation)
E.  Strip `someday_maybe` → introduce `intent`  (additive col + state strip)
F.  Strip `inbox` → introduce `clarified`       (additive col + state strip)
G.  Strip `done` → introduce `done_at`          (additive col + state strip)
H.  Strip `waiting_for` state                   (re-source list from `waiting_for` text col)
I.  FocusSession + strip `in_progress`          (load-bearing; retires `selected_for_today`)
J.  Final cleanup: drop `state` column          (the FSM is now empty; delete the husk)
K.  focus_session_review wrap-up UI             (follow-up; replaces / salvages PR #140)
```

**Hard ordering constraints:**
- D (TimeLog) must precede I (FocusSession), because I adds the `focus_session_id` FK to `time_logs` and wires `setCurrentTask` to drive TimeLog open/close.
- A, B, C, E, F, G, H must all precede J, because J only drops the column once `next_action` is the sole remaining value.
- I (FocusSession) doesn't strictly require E/F/G/H to ship first, but the planning-ritual rewrite inside I gets simpler if intent/clarified/done_at already exist (so the new list views can already filter on them).
- K depends on I.

**Soft ordering rationale:**
- A/B/C first: they're isolated cleanup, low risk, set the rhythm.
- D before E/F/G/H: TimeLog is foundational; later state-strip PRs can ignore time tracking entirely.
- E/F/G order is interchangeable.
- H (waiting_for) before I (FocusSession) keeps I focused on focus-session semantics rather than waiting-for re-sourcing.
- I is the load-bearing one; ships when all the smaller strips are out of the way.
- J is one-line in the column sense, but cleans up the FSM enum, `GtdStateMachine`, transition tests, ritual-bypass DAO methods.

**No "wire FocusSession alongside FSM" intermediate.** When I lands, FocusSession becomes the single source of truth for focus selection and current-task pointer in the same PR. `selected_for_today` and `state = 'in_progress'` retire in I, no flag-switching, no dual-write code that gets thrown away.

## PR A — Strip `scheduled` state

**Goal:** retire the half-baked `scheduled` state. First in the sequence because it's pure decorative removal — no replacement column needed; `due_date` already does the real work.

**Why this lands first:** investigation confirmed `scheduled` carries no behavior beyond a separate list view. There's no auto-transition on the date, no notification, no planning-ritual integration. `due_date` is the only piece that does real work, and it's already a separate column that survives the collapse.

**Migration:**
```sql
UPDATE todos SET state = 'next_action' WHERE state = 'scheduled';
-- due_date retained as-is
-- shrink GTD_STATES CHECK constraint to drop 'scheduled'
```

**Files to change:**
- `backend/alembic/versions/00XX_collapse_scheduled_state.py` — new migration.
- `backend/app/todos/models.py:30` — remove `'scheduled'` from `GTD_STATES`.
- `backend/app/todos/routes.py:41-42` — remove `state=scheduled` filter handling.
- `app/lib/models/todo.dart:9-46` — remove `GtdState.scheduled` enum value; update `fromString()` to map legacy `'scheduled'` → `nextAction` defensively for stale local DBs.
- `app/lib/models/gtd_state_machine.dart:38, 50-54` — remove `scheduled` from `allowedTransitions`.
- `app/lib/database/daos/inbox_dao.dart:151-190` — delete `transitionInboxToScheduled` (the two-hop atomic method that exists only because the FSM forbade `inbox → scheduled`).
- `app/lib/database/daos/todo_dao.dart:338-350` — delete `watchScheduledDueToday`.
- `app/lib/providers/daily_planning_provider.dart:160-165` — delete `scheduledDueTodayProvider`.
- `app/lib/providers/daily_planning_provider.dart:307-323` — `processInboxItem` collapses to a single transition.
- `app/lib/providers/gtd_lists_provider.dart:46-51` — delete `scheduledProvider`.
- `app/lib/screens/scheduled/scheduled_screen.dart` — delete file.
- `app/lib/screens/planning/steps/scheduled_review_step.dart:23-24` — drop the scheduled-specific sort branch (or delete the step entirely if redundant — verify in implementation).
- `app/lib/router.dart:11, 87-88` — remove the `/scheduled` route.
- `app/lib/screens/app_shell.dart` — remove the scheduled count from the nav bar.
- Tests:
  - `app/test/models/gtd_state_machine_test.dart` — remove scheduled-row tests, including `inbox → scheduled is rejected`.
  - `app/test/database/inbox_dao_test.dart:106` — remove the two-hop assertion.
  - `app/test/database/planning_dao_test.dart:128-174` — remove the scheduled-due-today tests.
- `NOTES.md` — append a one-liner under today's date noting the collapse and that the `inbox → scheduled` two-hop workaround (NOTES 2026-04-21 lines 41-42) retires with it.

**Reversibility:** if we want `scheduled` back later, it returns as a `TimeBlocker` under TMaYaD/Jeeves#181 — a much cleaner home than its current FSM perch.

## PR B — Strip `blocked` state and blocker functionality

**Goal:** retire the `blocked` state and the `blocked_by_todo_id` column. The cascade-unblock side effect on `done` retires with them. Lossy on the dependency hint between tasks — acceptable in alpha.

**Migration:**
```sql
UPDATE todos SET state = 'next_action' WHERE state = 'blocked';
ALTER TABLE todos DROP COLUMN blocked_by_todo_id;
-- shrink GTD_STATES CHECK constraint to drop 'blocked'
```

**Files to change:**
- `backend/alembic/versions/00XX_strip_blocked_state.py` — new migration.
- `backend/app/todos/models.py` — remove `'blocked'` from `GTD_STATES`; remove `blocked_by_todo_id` column.
- `backend/app/todos/schemas.py` — drop `blocked_by_todo_id` from read/write schemas.
- `backend/app/todos/routes.py` — remove `state=blocked` filter handling.
- `app/lib/models/todo.dart` — remove `GtdState.blocked`; remove `blockedByTodoId` field; update `fromString()` to map legacy `'blocked'` → `nextAction`.
- `app/lib/models/gtd_state_machine.dart` — remove `blocked` from `allowedTransitions`.
- `app/lib/database/daos/todo_dao.dart` — delete cascade-unblock side effect on `done` transition. Remove `blocked_by_todo_id` references in `_buildTransitionCompanion`. Drop the `state=blocked`/`state=nextAction` special case in `updateFields` (lines 484-543). Delete any blocker-specific watchers.
- `app/lib/database/powersync_schema.dart` — drop `blocked_by_todo_id` from the view.
- `app/lib/database/tables.dart` — drop column from Drift schema.
- UI: any "blocked by" picker / link UI gets deleted (search `blockedByTodoId` references across `app/lib/`). Any list view filtered to `state = blocked` (search `gtd_lists_provider.dart`) — delete.
- Tests: `app/test/database/todo_dao_test.dart` — strip cascade-unblock test and blocker-related tests. `app/test/models/gtd_state_machine_test.dart` — remove blocked rows.

**Reversibility:** comes back via TMaYaD/Jeeves#181 (polymorphic blockers) when typed blockers get designed.

## PR C — Strip `deferred` state

**Goal:** retire `deferred`. Per proposal §4.5, `deferred` evaporates — there is no replacement column. The verb "defer" gets repurposed later by PR E to mean "set intent = maybe."

**Migration:**
```sql
UPDATE todos SET state = 'next_action' WHERE state = 'deferred';
-- shrink GTD_STATES CHECK constraint to drop 'deferred'
```

**Files to change:**
- `backend/alembic/versions/00XX_strip_deferred_state.py` — new migration.
- `backend/app/todos/models.py` — remove `'deferred'` from `GTD_STATES`.
- `app/lib/models/todo.dart` — remove `GtdState.deferred`; map legacy `'deferred'` → `nextAction`.
- `app/lib/models/gtd_state_machine.dart` — remove `deferred` from `allowedTransitions`.
- `app/lib/database/daos/todo_dao.dart:417-438` — delete `deferTaskToSomeday` (it currently transitions to `deferred`). Callers either route to `deferTaskToMaybe` (introduced in PR E) or get inlined as a state-no-op.
- `app/lib/providers/gtd_lists_provider.dart` — delete any `deferredProvider`.
- UI: search `deferred` references across `app/lib/screens/`; delete list views and chip styles.
- Tests: `app/test/models/gtd_state_machine_test.dart` — remove deferred rows.

**Out of scope:** introducing `intent = 'maybe'` — that's PR E.

## PR D — TimeLog (TMaYaD/Jeeves#182)

**Goal:** introduce the `time_logs` table and route all task-focus time accounting through it. Additive only — no behavior visible to the user changes. Ships **without** `focus_session_id`; that column is added in PR I when FocusSession lands.

**Schema:**
```
time_logs
  id          UUID PK
  user_id     UUID NOT NULL              -- denormalized for PowerSync
  task_id     UUID NOT NULL FK → todos.id
  started_at  TIMESTAMPTZ NOT NULL
  ended_at    TIMESTAMPTZ NULL           -- null = currently active
```

Partial unique index `(user_id) WHERE ended_at IS NULL` — at most one open TimeLog row per user. Mirrors the FSM's "at most one in-progress" invariant at the time-tracking layer, and survives the cutover when FocusSession takes over.

**Files to change:**
- `backend/alembic/versions/00XX_add_time_logs.py` — new migration. Table + indexes only.
- `backend/app/todos/models.py` — `TimeLog` SQLAlchemy model.
- `backend/app/todos/schemas.py` — Pydantic read schema. No write schema — clients write through the synced view.
- `app/lib/database/powersync_schema.dart` — add `time_logs` to `powersyncSchema`. Use the same view-with-INSTEAD-OF-trigger pattern as `todos`/`tags`/`todo_tags` (NOTES.md 2026-04-22). Apply `_addColumnIfTable` helper for the Drift onUpgrade path (NOTES.md 2026-04-22 lines 53-55).
- `app/lib/database/tables.dart` — Drift table for the `NativeDatabase.memory()` test path.
- `app/lib/database/daos/time_log_dao.dart` — new DAO. Methods: `openLog({taskId})`, `closeLog({taskId})`, `watchActiveLog(userId)`, `totalMinutesForTask(taskId)`.
- `app/lib/database/daos/todo_dao.dart:267-276` — replace `time_spent_minutes` accumulation in `_buildTransitionCompanion` with `TimeLogDao.closeLog(taskId)` on leave-`in_progress`. Replace `in_progress_since` stamp on enter-`in_progress` with `TimeLogDao.openLog(taskId)`. `transitionState` still exists at this point (FSM not retired yet); these calls slot into the existing transition flow.
- `app/lib/providers/sprint_timer_provider.dart:612-632` — **delete** `_logSprintTimeToTask`. Pomodoro stops writing time directly. Sprint-number display (`sprint_timer_provider.dart:706`) reads `TimeLogDao.totalMinutesForTask` instead.
- `infra/powersync/sync-config.yaml:35-54` — add `by_user_time_logs` bucket, filter by `user_id` (mirror `by_user_todos`).
- `app/test/database/time_log_dao_test.dart` — new tests: open/close, single-active invariant, totalMinutesForTask correctness, multi-row-per-task within a span.
- `app/test/database/todo_dao_test.dart` — update existing time-tracking tests to assert TimeLog rows instead of `time_spent_minutes` increments. The "at most one in-progress per user" guard test stays as-is (still enforced via `transitionState`).

**`time_spent_minutes` strategy:** keep as denormalized cache, recomputed on TimeLog write. Display sites continue reading the column; cheap. Pre-existing time stays accurate (the existing value is a one-time sum at migration time; new time gets added via TimeLog → cache update). Drop the column in PR J if desired, or leave as cache indefinitely.

**Out of scope for PR D:** anything that mutates `state` semantics, anything that touches FocusSession (table doesn't exist yet), anything UI-visible. No `focus_session_id` column on `time_logs` — added in PR I.

## PR E — Strip `someday_maybe` → introduce `intent` column

**Goal:** add the `intent` column, migrate `someday_maybe` rows onto it, drop `someday_maybe` from the FSM. Full-stack atomic: schema + DAO + UI + tests in one PR.

**Schema:**
```sql
ALTER TABLE todos ADD COLUMN intent TEXT NOT NULL DEFAULT 'next';  -- 'next' | 'maybe' | 'trash'
UPDATE todos SET intent = 'maybe', state = 'next_action' WHERE state = 'someday_maybe';
-- shrink GTD_STATES CHECK constraint to drop 'someday_maybe'
```

`'trash'` is included in the column domain from day one (cheap) but no UI surfaces it yet.

**Files to change:**
- `backend/alembic/versions/00XX_intent_strip_someday.py` — new migration.
- `backend/app/todos/models.py` — add `intent` column; remove `'someday_maybe'` from `GTD_STATES`.
- `backend/app/todos/schemas.py` — add `intent` to read/write schemas.
- `app/lib/models/todo.dart` — add `intent` field; add `Intent` enum (`next`, `maybe`, `trash`); remove `GtdState.somedayMaybe`; map legacy `'someday_maybe'` → `nextAction` in `fromString()`.
- `app/lib/models/gtd_state_machine.dart` — remove `someday_maybe` from `allowedTransitions`.
- `app/lib/database/powersync_schema.dart` + `app/lib/database/tables.dart` — add `intent` column.
- `app/lib/database/daos/todo_dao.dart` — replace `watchSomedayMaybe` (or equivalent) with `watchMaybe` reading `WHERE intent = 'maybe' AND done_at IS NULL`. Replace any `transitionState(somedayMaybe)` callers with `setIntent(id, maybe)`. Reinstate the "defer" verb deleted in PR C as `deferTaskToMaybe` → `setIntent(maybe)`.
- `app/lib/providers/gtd_lists_provider.dart` — `somedayMaybeProvider` → `maybeProvider` reading the new filter.
- UI: rename Someday/Maybe screen header if needed; the chip/picker that previously set `state = someday_maybe` now calls `setIntent(maybe)`.
- Tests: rewrite someday tests around intent. `gtd_state_machine_test.dart` — remove someday rows.

**Out of scope:** the `'trash'` UX and any UI for it.

## PR F — Strip `inbox` → introduce `clarified` column

**Goal:** replace the `state = 'inbox'` semantics with a `clarified` boolean. The Inbox screen re-sources from `WHERE clarified = false`. Per proposal §6.4, `clarified` is an internal detail — not surfaced as a public API field.

**Schema:**
```sql
ALTER TABLE todos ADD COLUMN clarified BOOLEAN NOT NULL DEFAULT TRUE;
UPDATE todos SET clarified = false, state = 'next_action' WHERE state = 'inbox';
-- shrink GTD_STATES CHECK constraint to drop 'inbox'
```

New rows from the capture/inbox flow set `clarified = false` at insert. Rows created by any other path default to `clarified = true`.

**Files to change:**
- `backend/alembic/versions/00XX_clarified_strip_inbox.py` — new migration.
- `backend/app/todos/models.py` — add `clarified` column; remove `'inbox'` from `GTD_STATES`.
- `backend/app/todos/schemas.py` — keep `clarified` internal; do not expose in the public read/write schemas.
- `app/lib/models/todo.dart` — add `clarified` field; remove `GtdState.inbox`; map legacy `'inbox'` → `nextAction`.
- `app/lib/models/gtd_state_machine.dart` — remove `inbox` from `allowedTransitions`.
- `app/lib/database/powersync_schema.dart` + `app/lib/database/tables.dart` — add `clarified` column.
- `app/lib/database/daos/inbox_dao.dart` — capture flow inserts with `clarified = false`. The "process inbox item" path becomes "set `clarified = true`" plus whatever other field updates the user made (e.g. set `intent`, set `due_date`).
- `app/lib/database/daos/todo_dao.dart` — replace inbox-state watchers with `watchInbox` reading `WHERE clarified = false`.
- `app/lib/providers/gtd_lists_provider.dart` — `inboxProvider` reads the new filter.
- `app/lib/providers/daily_planning_provider.dart:307-323` — `processInboxItem` no longer transitions state; it updates fields and sets `clarified = true`.
- UI: Inbox screen reads from the new provider. Capture screen unchanged (still routes through `inbox_dao`).
- Tests: rewrite inbox tests around `clarified`. `gtd_state_machine_test.dart` — remove inbox rows.

## PR G — Strip `done` → rename `completed_at` to `done_at`

**Goal:** replace the terminal `state = 'done'` with a non-null `done_at` timestamp. No new column added — just rename the existing `completed_at` (same semantics). The Done list reads `WHERE done_at IS NOT NULL`.

**Schema:**
```sql
ALTER TABLE todos RENAME COLUMN completed_at TO done_at;
-- defensive: any 'done' rows that somehow had NULL completed_at get backfilled from updated_at
UPDATE todos SET done_at = updated_at WHERE state = 'done' AND done_at IS NULL;
UPDATE todos SET state = 'next_action' WHERE state = 'done';
-- shrink GTD_STATES CHECK constraint to drop 'done'
```

**Files to change:**
- `backend/alembic/versions/00XX_rename_completed_at_strip_done.py` — new migration.
- `backend/app/todos/models.py` — rename `completed_at` field to `done_at`; remove `'done'` from `GTD_STATES`.
- `backend/app/todos/schemas.py` — rename `completed_at` to `done_at` in read/write schemas. Search the codebase for any analytics or other readers of `completed_at` and update them.
- `app/lib/models/todo.dart` — rename `completedAt` field to `doneAt`; remove `GtdState.done`; map legacy `'done'` → `nextAction`.
- `app/lib/models/gtd_state_machine.dart` — remove `done` from `allowedTransitions`. (Cascade-unblock is already gone via PR B, so this is just removing the destination.)
- `app/lib/database/powersync_schema.dart` + `app/lib/database/tables.dart` — rename column.
- `app/lib/database/daos/todo_dao.dart` — add `markDone(id)` that sets `done_at = now()`. Replace `transitionState(...done)` callsites with `markDone`. Add `watchDone` reading `WHERE done_at IS NOT NULL`.
- `app/lib/providers/gtd_lists_provider.dart` — `doneProvider` reads the new filter.
- UI: the "complete" / checkmark control calls `markDone` instead of `transitionState(done)`. The Done screen reads from the new provider. Replace any `completedAt` UI references with `doneAt`.
- Tests: rewrite done tests around `done_at`; rename `completedAt` references throughout. `gtd_state_machine_test.dart` — remove done rows.

## PR H — Strip `waiting_for` state

**Goal:** retire `state = 'waiting_for'`. The existing `waiting_for` text column on `todos` (the "who/what we're waiting on") is **kept as-is** — the Waiting For list re-sources from `WHERE waiting_for IS NOT NULL` plus the standard actionable filters.

**Migration:**
```sql
UPDATE todos SET state = 'next_action' WHERE state = 'waiting_for';
-- shrink GTD_STATES CHECK constraint to drop 'waiting_for'
-- waiting_for column retained
```

**Files to change:**
- `backend/alembic/versions/00XX_strip_waiting_for_state.py` — new migration.
- `backend/app/todos/models.py` — remove `'waiting_for'` from `GTD_STATES`.
- `app/lib/models/todo.dart` — remove `GtdState.waitingFor`; map legacy `'waiting_for'` → `nextAction`.
- `app/lib/models/gtd_state_machine.dart` — remove `waiting_for` from `allowedTransitions`.
- `app/lib/database/daos/todo_dao.dart` — replace `watchWaitingFor` (state-based) with one reading `WHERE waiting_for IS NOT NULL AND clarified = true AND done_at IS NULL AND intent = 'next'`.
- `app/lib/providers/gtd_lists_provider.dart` — `waitingForProvider` reads the new filter.
- UI: the "convert to waiting for" verb sets the `waiting_for` text column instead of transitioning state. The Waiting For screen reads from the new provider.
- Tests: rewrite waiting-for tests around the column-based filter.

**Out of scope:** any Waiting For tag-system migration (open question; column path is cheaper).

## PR I — FocusSession + strip `in_progress` (load-bearing)

**Goal:** introduce FocusSession as the single source of truth for "what's the focused task" and "which tasks are on today's plan." Retire `state = 'in_progress'`, `selected_for_today`, `daily_selection_date`, and `in_progress_since` in the same PR. No flag-switching, no dual-write code that gets thrown away.

By the time this PR lands, only `next_action` and `in_progress` remain in the `state` column. After this PR, only `next_action` remains. PR J then drops the column entirely.

**Schema:**
```sql
-- new tables
CREATE TABLE focus_sessions (
  id              UUID PRIMARY KEY,
  user_id         UUID NOT NULL,
  started_at      TIMESTAMPTZ NOT NULL,
  ended_at        TIMESTAMPTZ NULL,
  current_task_id UUID NULL REFERENCES todos(id)
);
CREATE UNIQUE INDEX focus_sessions_one_open_per_user
  ON focus_sessions(user_id) WHERE ended_at IS NULL;

CREATE TABLE focus_session_tasks (
  focus_session_id UUID NOT NULL REFERENCES focus_sessions(id),
  task_id          UUID NOT NULL REFERENCES todos(id),
  position         INT  NOT NULL,
  PRIMARY KEY (focus_session_id, task_id)
);

-- wire TimeLog to FocusSession (the deferred step from PR D)
ALTER TABLE time_logs ADD COLUMN focus_session_id UUID NULL REFERENCES focus_sessions(id);

-- backfill: synthesize one open FocusSession per user that has either
--   (a) any task with state = 'in_progress', or
--   (b) any task with selected_for_today = true.
-- Members come from selected_for_today rows (and the in_progress task if any).
-- current_task_id := the in_progress task if any, else NULL.
-- After backfill: collapse state = 'in_progress' rows to state = 'next_action'.

UPDATE todos SET state = 'next_action' WHERE state = 'in_progress';
ALTER TABLE todos DROP COLUMN selected_for_today;
ALTER TABLE todos DROP COLUMN daily_selection_date;
ALTER TABLE todos DROP COLUMN in_progress_since;
-- shrink GTD_STATES CHECK constraint to drop 'in_progress'
```

The "at most one in-progress per user" invariant is now enforced structurally by the partial unique index on `focus_sessions`, replacing the FSM-level guard.

**Files to change (schema / sync / models):**
- `backend/alembic/versions/00XX_focus_sessions_strip_in_progress.py` — new migration.
- `backend/app/todos/models.py` — `FocusSession`, `FocusSessionTask` models. Remove `'in_progress'` from `GTD_STATES`. Drop `selected_for_today`, `daily_selection_date`, `in_progress_since`. Add `focus_session_id` to `TimeLog`.
- `backend/app/todos/schemas.py` — read schemas for the new tables.
- `app/lib/database/powersync_schema.dart` + `app/lib/database/tables.dart` — add new tables; drop the dropped columns; add `focus_session_id` to `time_logs`. Verify whether `_dropColumnIfTable` exists; create if not (NOTES.md 2026-04-22 line 55).
- `infra/powersync/sync-config.yaml` — add `by_user_focus_sessions` and `by_user_focus_session_tasks` buckets. `by_user_time_logs` already exists.
- `app/lib/models/todo.dart` — remove `GtdState.inProgress`; remove `selectedForToday`, `dailySelectionDate`, `inProgressSince` fields; map legacy `'in_progress'` → `nextAction`.
- `app/lib/models/gtd_state_machine.dart` — remove `in_progress` from `allowedTransitions`. (After this, only `next_action` is in the FSM. The file gets deleted in PR J.)

**Files to change (DAO):**
- `app/lib/database/daos/focus_session_dao.dart` — new DAO. Methods: `openSession({userId, taskIds})`, `closeSession({sessionId})`, `setCurrentTask({sessionId, taskId?})`, `watchActiveSession(userId)`, `watchSessionTasks(sessionId)`. `setCurrentTask` is the meeting point with TimeLog: with non-null `taskId` it closes any open TimeLog row and opens a new one with `focus_session_id = sessionId`; with null, it closes the open row and clears `current_task_id`.
- `app/lib/database/daos/time_log_dao.dart` — extend `openLog` to accept optional `focusSessionId`.
- `app/lib/database/daos/todo_dao.dart:267-300` — strip the `_buildTransitionCompanion` branches that handle `in_progress` enter/leave (TimeLog open/close moves to `setCurrentTask`).
- `app/lib/database/daos/todo_dao.dart:372-414` — delete `selectForToday`, `skipForToday`, `undoReview`, `clearTodaySelections`, `watchSelectedForToday`, `watchNextActionsForPlanning`. Callers move to `FocusSessionDao`.

**Files to change (ritual / UI — wire, do NOT rewrite):**

PR I's UI scope is deliberately minimal: thread the existing screens through FocusSession instead of FSM/`selected_for_today`. The new ritual UX from TMaYaD/Jeeves#180 lands in follow-up PRs after #180 ships its design.

- `app/lib/providers/daily_planning_provider.dart` — replace `selectForToday(...)` write paths with `FocusSessionDao.openSession({taskIds})`. Read paths that consult `selected_for_today` switch to `watchSessionTasks`. `planningToday()` and date arithmetic disappear; FocusSession owns its own start/end timestamps. This kills the `project_day_boundary` bug class structurally.
- `app/lib/screens/planning/planning_ritual_screen.dart` and steps — minimal change: the final step calls `FocusSessionDao.openSession({taskIds: selected})` instead of per-task `selectForToday`. Visual structure unchanged.
- `app/lib/screens/focus_screen.dart` and `app/lib/screens/active_focus_screen.dart` — read `focus_session.current_task_id` via `watchActiveSession`. Starting a task calls `setCurrentTask(taskId)` (transitively opens a TimeLog row). Stopping calls `setCurrentTask(null)`. Completing calls `markDone(taskId)` and then `setCurrentTask(null)`.
- `app/lib/providers/sprint_timer_provider.dart` — read `focus_session.current_task_id` instead of `state == 'in_progress'` to know which task the sprint applies to.
- `app/lib/providers/focus_session_provider.dart:111-125` — existing client-side pause/resume stays as-is; explicitly does not split TimeLog rows.

**LoC expectation:** removed > added. If the diff trends the other way, audit for accidental scope creep into TMaYaD/Jeeves#180 territory.

**Tests:**
- New `app/test/database/focus_session_dao_test.dart`: open/close, single-active invariant per user, current-task pointer flips, task list immutability post-open, TimeLog open/close coupling via `setCurrentTask`.
- `app/test/database/todo_dao_test.dart` — strip the "at most one in_progress" test (now structural via the partial unique index), strip `selectForToday`/`skipForToday` tests.
- `app/test/database/planning_dao_test.dart` — rewrite around FocusSession.
- `app/test/providers/daily_planning_provider_test.dart` — rewrite around FocusSession lifecycle.
- New `app/test/integration/focus_session_lifecycle_test.dart` — end-to-end: open session with N tasks, set current, switch current (assert TimeLog rows split), close session (assert TimeLog row closes, current_task_id clears).

**Out of scope:**
- New ritual / planning UX (TMaYaD/Jeeves#180). PR I wires the existing UI to FocusSession verbatim; the redesigned flow lands in follow-up PRs after #180 ships its design.
- Session-review wrap-up UI (per-task rollover/leave/maybe). That's PR K.
- Polymorphic blockers (TMaYaD/Jeeves#181).
- Clarify & Organise rework (TMaYaD/Jeeves#184).

## PR J — Final cleanup: drop the FSM

**Goal:** with `next_action` the only remaining `state` value, drop the column and delete the FSM scaffolding.

**Schema:**
```sql
ALTER TABLE todos DROP COLUMN state;
-- time_spent_minutes is kept as a cache; instrumentation/metrics will inform a later drop decision.
-- completed_at is already gone (PR G renamed it to done_at).
```

**Files to change:**
- `backend/alembic/versions/00XX_drop_state_column.py` — new migration.
- `backend/app/todos/models.py` — remove `state` column and `GTD_STATES` constant.
- `backend/app/todos/schemas.py` — remove `state` from read/write schemas.
- `backend/app/todos/routes.py` — remove any state-filter parameters.
- `app/lib/models/todo.dart:9-46` — delete `GtdState` enum and `fromString`. Keep `Intent`.
- `app/lib/models/gtd_state_machine.dart` — **delete file**.
- `app/lib/database/daos/todo_dao.dart:205-300` — delete `transitionState` and `_buildTransitionCompanion` (now empty / only-next_action). The simple field-update methods (`markDone`, `setIntent`, `updateFields`) introduced across PRs E/F/G remain.
- `app/lib/database/powersync_schema.dart` + `app/lib/database/tables.dart` — drop `state` column.
- `infra/powersync/sync-config.yaml` — drop `state` from select lists.
- `app/test/models/gtd_state_machine_test.dart` — **delete file**.
- `app/test/database/todo_dao_test.dart` — strip remaining `transitionState` tests.

**Verification of completeness:** grep for `transitionState`, `GtdState`, `gtd_state_machine`, `GTD_STATES` across both `app/` and `backend/`. Zero references after this PR.

## PR K — focus_session_review wrap-up UI (follow-up)

**Goal:** the wrap-up flow at session close where the user picks per-task disposition (rollover, leave, maybe / trash).

**Depends on:** PR I (FocusSession in place) and PR J (FSM dropped).

**Scope:** broken out so PR I stays focused on the cutover. This is where PR TMaYaD/Jeeves#140 (Evening Shutdown) gets revisited — salvage the UI scaffolding, rewrite the data interactions to use the new model. Per Decision 9, salvage-vs-rewrite is decided after PR I lands and the new shape is visible.

**Sketched here only so the sequence terminates cleanly.** Detailed plan deferred until PR I is in flight.

## Investigation tasks (not blockers)

One spike worth doing during PR D so the recipe is right before PR I follows the same pattern:

- **PowerSync sync-rule pattern for new tables.** Verify that `time_logs` (PR D) rides the same `by_user_*` bucket shape as `todos` without surprises. Whatever pattern lands in PR D becomes the recipe for `focus_sessions` / `focus_session_tasks` in PR I.

## Verification

Per-PR (each must pass before merge):
- `make lint` and `make test` clean.
- New DAO tests pass (PR D introduces TimeLog tests; PR I introduces FocusSession tests).
- Migration round-trips on a seeded DB: spin up an alpha-shaped DB with rows in every state currently allowed, run the migration, assert the post-state matches the backfill table for that PR (PRs A, B, C, E, F, G, H, I, J).
- PowerSync end-to-end on emulator with two devices: write on device A, observe on device B. Required for any PR that adds/removes a synced table or column (D, I, J in particular). Use the emulator tap coordinates in `docs/TESTING.md`.

State-strip PRs (A, B, C, E, F, G, H):
- After the migration runs, the relevant state value is absent from `GTD_STATES` and absent from any persisted row. The replacement filter (where applicable: `intent`, `clarified`, `done_at`, `waiting_for`) drives the corresponding list view.
- `transitionState` callers that previously targeted the stripped state either route to a new field-update method (e.g. `markDone`, `setIntent`) or are deleted.

Cutover-specific (PR I):
- Manual smoke: open the planning ritual, select 3 tasks, start the session, switch focus between them, complete one, close the session. Verify in DB: one `focus_sessions` row with the expected lifecycle, three `focus_session_tasks` rows, ≥3 `time_logs` rows with correct `started_at`/`ended_at` and `focus_session_id`. The completed task has `done_at` set; the other two retain `intent = 'next'`.
- Verify the `project_day_boundary` bug class is gone: change device timezone mid-session and confirm the open session does not flip identity.
- Verify Pomodoro: start a sprint mid-task-span, let it expire, verify a sprint-end notification fires AND no extra TimeLog row is written (the running TimeLog row stays open across the sprint boundary).

Final-cleanup-specific (PR J):
- Grep `transitionState`, `GtdState`, `gtd_state_machine`, `GTD_STATES`, `state` (as a column name in queries) across `app/` and `backend/`. Zero references after PR J.

End-to-end (after PR K):
- Full ritual loop: morning planning → focus session with task switching and pauses → session-review wrap-up with per-task disposition → next morning's planning shows the rolled-over tasks pre-selected.

## File touchpoint summary

Read-the-room reference for trixy / future agents:

| Concern | Today (file:line) | After PR J | Retired by |
|---|---|---|---|
| State enum | `backend/app/todos/models.py:30`, `app/lib/models/todo.dart:9-46`, `app/lib/models/gtd_state_machine.dart:28-77` | Deleted | A → I shrink the values; J drops the column and FSM file |
| Transition logic | `app/lib/database/daos/todo_dao.dart:205-300` | Replaced with field-update methods | Each strip PR converts its callers; J deletes the husk |
| Time accumulation | `app/lib/database/daos/todo_dao.dart:267-276`, `app/lib/providers/sprint_timer_provider.dart:612-632` | `time_log_dao.dart` | D |
| Focus selection | `selectForToday` / `selected_for_today` flag | `focus_session_dao.openSession` + `focus_session_tasks` | I |
| Active task pointer | `state == 'in_progress'` + "at most one" guard | `focus_sessions.current_task_id` + partial unique index | I |
| Blocker hint | `blocked_by_todo_id` | Removed (no replacement in alpha; TMaYaD/Jeeves#181 covers later) | B |
| Waiting-for hint | `waiting_for` text column + `state = waiting_for` | `waiting_for` text column kept; state value gone | H |
| "Maybe" list | `state = 'someday_maybe'` | `intent = 'maybe'` | E |
| "Inbox" list | `state = 'inbox'` | `clarified = false` | F |
| "Done" list | `state = 'done'` | `done_at IS NOT NULL` | G |
| Day boundary | `planningToday()` in `daily_planning_provider.dart` | Gone — FocusSession owns timestamps | I |
