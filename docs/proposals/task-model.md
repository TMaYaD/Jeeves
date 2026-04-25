# Task Domain Model — Proposal

> **Status:** Domain-modelling proposal & discussion record. Not current-state
> architecture. Implementation is unchanged at the time of writing;
> `docs/ARCHITECTURE.md` remains the source of truth for what is built today.
> Decisions captured here will land through follow-up issues.
>
> **Date:** 2026-04-25
> **Origin:** Session reviewing the original Task FSM (reference SVG)
> against the implemented FSM in `app/lib/models/gtd_state_machine.dart` and
> `app/lib/database/daos/todo_dao.dart`.

---

## 1. Why this document exists

The Task lifecycle was originally sketched as a finite state machine. The
implementation in code is also nominally an FSM, but it has accumulated drift:
states the original FSM didn't anticipate, missing transitions that were
intended, spurious transitions with no basis in the original model, and
side-flags (`selected_for_today`, `in_progress_since`, `blocked_by_todo_id`)
that carry state outside the FSM.

This document:

1. records the drift between intent and implementation,
2. classifies the drift as intentional revision, implementation noise, or
   genuinely-open,
3. argues the FSM itself is the wrong abstraction, and
4. proposes an orthogonal decomposition that retires the global FSM in favour
   of small, locally-scoped state machines plus polymorphic blockers and a
   first-class `FocusSession` entity.

The proposal is **not yet decided.** Open questions are called out in §8.

---

## 2. Snapshot: the current implementation

**States** (`backend/app/todos/models.py:30`, `app/lib/models/todo.dart:9-18`):
`inbox`, `next_action`, `waiting_for`, `scheduled`, `in_progress`, `blocked`,
`someday_maybe`, `deferred`, `done`. Nine states. `done` is terminal.

**Transition rules** (`app/lib/models/gtd_state_machine.dart:28-77`):

```text
inbox         → next_action, waiting_for, someday_maybe, blocked, done
next_action   → in_progress, scheduled, waiting_for, someday_maybe, blocked, done
waiting_for   → next_action, someday_maybe, blocked, done
scheduled     → in_progress, waiting_for, someday_maybe, blocked
in_progress   → deferred, blocked, done
blocked       → next_action, done
someday_maybe → next_action, blocked, done
deferred      → next_action, blocked, someday_maybe, done
done          → ∅                                 (terminal)
```

**Validation entry point:** `TodoDao.transitionState()`
(`app/lib/database/daos/todo_dao.dart:212-300`).

**Embedded side effects:**

- Entering `in_progress`: stamps `in_progress_since`.
- Leaving `in_progress`: accumulates elapsed minutes into `time_spent_minutes`,
  clears `in_progress_since`.
- Entering `done`: cascades — every task with `blocked_by_todo_id = this.id`
  in `blocked` is auto-transitioned to `next_action`
  (`todo_dao.dart:248-262`).
- Entering `deferred`: clears `selected_for_today = false`.

**Imperative guard:** at most one task per user can be in `in_progress`
(`todo_dao.dart:227-238`). Enforced by query, not by the type system.

**Ritual-bypass methods** that mutate state without going through
`GtdStateMachine.validate()`:

- `rolloverTask` (`todo_dao.dart:537-573`)
- `returnToNextActions` (`todo_dao.dart:583-610`)
- `deferTaskAtShutdown` (`todo_dao.dart:433-464`)
- `selectForToday` / `skipForToday` (`todo_dao.dart:375-421`) — these don't
  mutate FSM state but do mutate the orthogonal `selected_for_today` flag.

**Orthogonal flags** carried on the task row that are not part of the FSM:

- `selected_for_today` (boolean, nullable)
- `daily_selection_date` (ISO-8601 date string)
- `in_progress_since` (ISO-8601 timestamp)
- `time_spent_minutes` (integer, ≥0)
- `blocked_by_todo_id` (UUID, nullable)
- `waiting_for` (free-text note)

---

## 3. Original FSM intent (the SVG)

The reference FSM has nine nodes and the following transitions
(paraphrased from the SVG labels):

```text
Inbox         → Next         (Clarify)
Inbox         → Waiting For  (Clarify)
Inbox         → Scheduled    (Clarify)
Inbox         → Blocked      (Clarify)
Inbox         → Done         (Under 2 min)

Waiting For   → Next         (response received — unlabeled in SVG)
Scheduled     → Next         (On the day)
Blocked       → Next         (Blocker Done)

Next          → Focus        (DPR — Daily Planning Review)
Focus         → In Progress  (Start)
In Progress   → Focus        (Stop)
In Progress   → In Progress  (Pause)
In Progress   → Done         (Done)

Focus         → Focus        (Roll Over)
Focus         → Next         (Return to Next)
Focus         → Maybe        (Defer)
Focus         → Scheduled    (Defer w/ Date)

Maybe         → Next         (Weekly Review)
```

Notable differences from the implementation, before classification:

- The original FSM has **`Focus`** as a state; the code has it as a flag
  (`selected_for_today`).
- The original FSM has **no `deferred` state**; the code does.
- The original FSM has **`Pause`** as an `In Progress → In Progress`
  self-loop; the code has no equivalent.
- The original FSM has **`Weekly Review`**; the code has no surfacing of
  this ritual, though the underlying FSM edge (`someday_maybe → next_action`)
  does exist.

---

## 4. Drift analysis

Each difference classified as:

- **Intentional revision** — implementation is intentionally ahead of the
  reference FSM; keep.
- **Noise** — code drifted accidentally; fix toward the reference FSM.
- **Open** — reference FSM never committed on it; needs a deliberate decision.

### 4.1 `Focus` as state vs. as flag — **NOISE (load-bearing)**

The implementation flattens Focus into the `selected_for_today` boolean, which
forces every Focus-domain operation (Roll Over, Return to Next, Defer, Defer
w/ Date) to either bypass the state machine or be re-encoded as
flag-mutations. This is the single largest source of downstream drift.

Evidence it's noise rather than intentional:

- `NOTES.md` 2026-04-21 explicitly logs the `inbox → next_action → scheduled`
  two-hop as a *workaround* forced by the state machine. With `Focus` as a
  state (or, equivalently, a session-membership relation), `Defer w/ Date` is
  a clean edge.
- Three DAO methods (`rolloverTask`, `returnToNextActions`,
  `deferTaskAtShutdown`) explicitly bypass `GtdStateMachine.validate()`
  because `in_progress → next_action` is forbidden. They wouldn't need to
  exist if Focus weren't flattened.
- The "at most one in-progress" guard has to be enforced imperatively; with
  Focus as a structural concept, it falls out of having a single
  `current_task_id` slot per session.

### 4.2 `Pause` self-loop — **NOISE**

Not implemented. No replacement exists; users cannot pause without exiting
`in_progress` and breaking time-tracking continuity. Should be filed as a
missing-feature story.

### 4.3 Weekly Review ritual — **NOISE / missing feature**

The FSM edge `someday_maybe → next_action` exists, but no UI ritual surfaces
it. Should be filed as a missing-feature story; see also §10 on terminology.

### 4.4 Automatic blocker cascade — **INTENTIONAL REVISION (keep)**

Code automates `Blocked → Next` when the blocker reaches `done`. The
reference FSM shows this as a labeled transition without specifying who
triggers it. Automation is the correct call; the manual alternative leaves
orphaned blocked tasks.

### 4.5 `deferred` state — **OPEN, leaning NOISE**

Used for `in_progress → deferred` (Abandon mid-day). Two readings:

1. *Necessary refinement.* Distinguishes "abandoned today, still a Next
   Action" from "Someday/Maybe."
2. *Spurious.* Equivalent to "Stop + clear `selected_for_today`," which the
   reference FSM's `Focus → Next (Return to Next)` already covers.

In the proposed model (§7) the question dissolves: "abandoned today" is
expressed as `intent=next` + remove from current `FocusSession.tasks` (which
the user may or may not actually do — see §6.3) + (optionally) `intent=maybe`
if the user is permanently abandoning. Three values of intent + session
membership cover the space without a `deferred` bucket.

### 4.6 Permissive direct edges — **OPEN**

The implementation allows many transitions the reference FSM never authorized
(`next_action → waiting_for`, `next_action → someday_maybe` direct,
`scheduled → waiting_for`, `inbox → someday_maybe`, etc.). The reference FSM
is ritual-gated and disciplined; the implementation is lax.

This is a deliberate-decision question: should the model enforce GTD ritual
cadence, or let users freely reclassify? The proposed model in §7 defers this
question by making intent a single mutable field rather than a state — the
question becomes "what UI affordances exist for changing intent" rather than
"what FSM transitions are allowed."

### 4.7 Several "minor" missing edges (`waiting_for → done`,
`scheduled → in_progress`, `blocked → done`, etc.) — **NOISE**

These are routine edges the SVG omitted but that real workflows need
(completing a waiting-for via `Done`, starting a scheduled item directly).
Mostly cosmetic; addressed structurally by §7.

---

## 5. Diagnosis: the FSM is the wrong abstraction

The implementation is not really an FSM. It is a state field with permissive
transitions, supplemented by a half-dozen orthogonal flags carrying
real state outside the state machine. It pays the cost of an FSM —
centralized validation, transition-tied side effects, ritual-bypass methods,
imperative guards — without the benefit (a constrained state space in which
illegal states are unrepresentable).

The reason: the axes the FSM is trying to encode are genuinely orthogonal.

| Concern                     | Currently encoded as                          | Naturally a... |
|-----------------------------|-----------------------------------------------|----------------|
| Has it been clarified?      | `state == 'inbox'`                            | boolean        |
| Does the user want to do it?| `state == 'next_action'` vs `'someday_maybe'` | enum / intent  |
| Is it complete?             | `state == 'done'` (and/or `completed`)        | timestamp      |
| What's blocking it?         | `state` ∈ {`waiting_for`, `scheduled`, `blocked`} + `blocked_by_todo_id`, `waiting_for` text | list of blockers |
| Is it on today's plan?      | `selected_for_today`                          | session-membership |
| Is it the active task?      | `state == 'in_progress'`                      | session pointer + timer |

Forcing six orthogonal axes into one `state` field produces:

- combinatorial explosion when more than one axis applies (a task blocked by
  another task **and** waiting on a person can't be expressed cleanly),
- side flags multiplying to encode the axes that didn't fit
  (`selected_for_today`, `blocked_by_todo_id`, `in_progress_since`, ...),
- transitions that have to bundle unrelated mutations (entering `done` does
  cascade-unblocking; entering `deferred` mutates the day-flag),
- ritual-bypass methods to handle legitimate transitions the FSM forbade.

---

## 6. Proposed model: orthogonal decomposition

The proposal is to retire the global Task FSM and replace it with:

```text
Task
  clarified:    bool                          # inbox vs clarified
  intent:       {next, maybe, trash}
  done_at:      Timestamp?                    # null = not done; set = done
  blockers:     List<Blocker>                 # polymorphic; AND semantics

  derived:
    actionable? = clarified
                  && !done_at
                  && intent == next
                  && blockers.all(satisfied)

Blocker  (polymorphic — see §6.2 for nuance)
  TaskBlocker     { blocking_task_id }
  PersonBlocker   { person, note }            # may itself spawn an action
  TimeBlocker     { schedule }                # specific time OR recurring window
  LocationBlocker { place }                   # e.g. "fix garage door at home"

FocusSession
  id, started_at, ended_at
  tasks:           List<TaskRef>              # locked at session start
  current_task_id: TaskRef?                   # the "in progress" pointer

PeriodicSession                               # NOT a generalization of Focus
  (separate entity — see §6.1)

Timer  (per FocusSession)
  state:     {idle, running, paused}          # small local FSM — fine
  intervals: List<{start, end}>               # appended on stop; sums to task.time_spent
```

Wins relative to the current FSM:

- **"In Progress" is not a state.** It is `session.current_task_id` plus a
  running timer. The "at most one" guard becomes structural.
- **Pause/Unpause are timer ops.** Closes the missing feature without adding
  a state.
- **`deferred` evaporates.** "Abandon mid-task" is `intent = maybe` (or just
  removing from active focus); the task remains in
  `FocusSession.tasks` for cosmetic continuity if the session is open (see
  §6.3).
- **Day-boundary date arithmetic disappears.** `FocusSession` owns its own
  `started_at`/`ended_at`; "today" is UI copy. The bug class flagged in the
  `project_day_boundary` memory is structurally impossible.
- **Polymorphic blockers** subsume `waiting_for`, `scheduled`, and `blocked`
  with cleaner semantics — including multiple simultaneous blockers (§6.2).
- **Ritual-bypass methods retire** because the FSM they were bypassing no
  longer exists.

The proposal does *not* eliminate state machines wholesale. Two small ones
survive, both locally scoped:

- `Timer.state ∈ {idle, running, paused}` — single-purpose, doesn't tangle
  with task semantics.
- `FocusSession.state ∈ {open, closed}` — implicit in
  `ended_at is null` / `is set`; fine.

---

## 6.1 FocusSession ≠ PeriodicSession

**Decision (this session):** they are distinct entities, not two
configurations of one.

| Concern                | FocusSession                           | PeriodicSession                        |
|------------------------|----------------------------------------|----------------------------------------|
| Purpose                | Act on a curated list                  | Curate and organize the list           |
| Where the work happens | Mostly outside the app                 | In the app                             |
| App's role             | Time tracking, attention aid           | Inbox processing, intent grooming, blocker review |
| Mutates `task.intent`? | Rarely (defer to maybe is the edge)    | Centrally — the whole point            |
| Mutates `task.blockers`? | No                                   | Yes                                    |
| Cadence                | Per focus block (e.g. daily)           | Periodic (e.g. weekly)                 |

Trying to unify them under a "Session" abstraction trades small DRY savings
for friction at every site that has to fork on `kind`. They share so little
behaviour that the abstraction would be cosmetic.

The terminology choice (§10) reflects this: `focus_session_*` and
`periodic_session_*` are sibling concepts, not parameterizations of a parent.

---

## 6.2 Blockers — polymorphic, but the polymorphism is non-trivial

All three current blocker-flavoured states share a shape ("user wants to act
but can't yet, because of <something>"), but the differences are real and
worth respecting in the schema.

**WaitingFor is itself often actionable.** "Waiting on Alice's reply" can
spawn "Follow up with Alice if no reply by Tuesday." The blocker is
sometimes a passive wait, sometimes a reminder to chase. The data model
should not assume PersonBlockers are inert.

**TimeBlockers come in two flavours:**

1. *Specific time.* "Renew the lease after 30 November." Satisfied when
   `now >= target_time`.
2. *Recurring window.* "Open mic nights at the pub — Tuesdays and
   Thursdays." Satisfied when *now* falls inside one of a recurring set of
   windows. These are non-trivial — RFC 5545 RRULE territory — and worth a
   focused schema pass.

**TaskBlockers may not belong here at all.** Strict GTD says: if Task A
depends on Task B, that's a *project*, not a blocker. Pragmatically, modelling
a project for one or two dependencies is overkill; modelling it as a
blocker is light-touch.

**LocationBlockers** ("Fix the garage door — at home", "Pick up the parcel —
at the post office") are a real GTD concept (the classic "@home", "@office"
contexts) but are not currently modelled. The codebase has a `locationId`
field on todos and a `[Design]` epic for geofenced surfacing
(TMaYaD/Jeeves#46), but no notion of a location *blocking* a task until the
user is in the right place.

The polymorphism is non-trivial enough that this should be domain-modelled
as an epic before being split into per-variant stories. Tracked as a single
epic.

Decisions deferred:
- Does the model need a first-class Project concept? (Currently no project
  entity exists.)
- If TaskBlockers stay, how are cycles prevented? (Today: not at all.)
- Schema for the polymorphism — single table with `kind` + nullable FKs vs
  separate tables per kind. Single-table is the pragmatic default.
- LocationBlocker evaluation: lazy ("am I at home now?") vs. push (geofence
  triggers a notification when the user enters the place).

These are open questions, not proposed decisions.

---

## 6.3 FocusSession task list is immutable mid-session

**Decision (this session):** the *list* of tasks in a `FocusSession` is
locked at session start. Task *attributes* (e.g. `done_at`) can mutate during
the session.

Specifically:

- A task that the user "abandons" mid-session (e.g. sets `intent = maybe`)
  **stays in the session's task list** until the session is reviewed and
  closed. UI indicates the change cosmetically (e.g. greyed out for
  Maybe, strikethrough for Done) so the list does not jump beneath the
  user's feet.
- New tasks cannot be pulled into an open session. They go into the next
  session's candidate pool.
- The moment of curation is the planning step at session start
  (`focus_session_planning`).

**Rollover is intentional, not automatic.** At
`focus_session_review` the user explicitly decides, per task, whether to:

- roll it over (pre-populate it into the next session's candidate list),
- leave it (it returns to the general Next pool, may be picked at next
  planning), or
- move it to Maybe.

Rollover is conceptually a shortcut for "leave it + select it again at next
planning." Equivalent outcomes; the shortcut just saves a step.

This rules out two implementation temptations:
1. *Auto-rolling all unfinished tasks.* No.
2. *Mutating the session's task list during the session* (e.g. removing a
   task the user defers to Maybe). No — only attributes mutate, not
   membership.

---

## 6.4 `clarified: bool` — placeholder, not the final word

The `clarified` boolean works for now but is structurally weaker than the
real workflow. In practice, Inbox items don't map 1:1 to clarified tasks:

- one Inbox item often splits into multiple tasks ("Project X" → "draft
  outline," "send to reviewers," "schedule kickoff"),
- multiple Inbox items often merge into one task (the same idea echoing in
  different contexts at different moments).

A future "Clarify & Organise" rework will likely need:

- one-to-many splitting ("turn this Inbox item into N tasks"),
- many-to-one merging,
- an Inbox-item entity distinct from Task (where today they are the same row
  with `state == 'inbox'`).

**Engineering directive:** keep code touching the inbox/clarification flow
*reversible.* Avoid baking "Inbox is just a Task with `clarified=false`" into
load-bearing assumptions. Concretely:

- Don't expose `clarified` as a public API field; treat it as an internal
  detail that may be replaced by an `InboxItem` entity later.
- Keep clarification UI flows isolated behind a notifier/service interface
  rather than threading raw FSM transitions through call sites.
- New code that adds Inbox-specific behaviour should be easy to lift into a
  separate entity later.

---

## 7. The proposed model, end to end

```text
                    ┌─────────────────────┐
                    │       INBOX         │  (Task, clarified=false)
                    └──────────┬──────────┘
                               │ Clarify (may split / merge — future rework)
                               ▼
                    ┌─────────────────────┐
                    │  Task                │
                    │   clarified=true     │
                    │   intent ∈           │
                    │     {next,maybe,trash}│
                    │   blockers: [...]    │
                    │   done_at?           │
                    └──────────┬──────────┘
                               │
   actionable? = clarified ∧ ¬done_at ∧ intent=next ∧ blockers.all(satisfied)
                               │
                               ▼
       ┌────────────────────────────────────────────────────┐
       │                FocusSession                        │
       │                                                    │
       │   tasks    : locked at start                       │
       │   current  : pointer (the "in progress" task)      │
       │   timer    : {idle, running, paused}               │
       │                                                    │
       │  • complete a task → set its done_at               │
       │  • defer to Maybe  → set its intent = maybe        │
       │    (task stays in this session's list, greyed)     │
       │  • pause/unpause   → timer state, no task mutation │
       │                                                    │
       │  ─ session_review (close) ─────────────────────────│
       │   for each unfinished task, user picks:            │
       │     • rollover → preselect for next session        │
       │     • leave    → return to Next pool               │
       │     • maybe    → intent = maybe                    │
       └────────────────────────────────────────────────────┘

Independently:

       ┌────────────────────────────────────────────────────┐
       │                PeriodicSession                     │
       │   curate intent (next ↔ maybe ↔ trash)             │
       │   review blockers, drop stale ones                 │
       │   process inbox (clarify & organise)               │
       └────────────────────────────────────────────────────┘
```

---

## 8. Open questions

These are *not* decided:

1. **Projects vs. TaskBlockers.** Does the model need a first-class Project
   entity? If yes, how heavy? If no, how do we handle non-trivial
   dependency chains?
2. **Recurring-window TimeBlockers.** Schema and evaluation strategy. RRULE
   subset vs. our own enum vs. cron-like syntax.
3. **Permissiveness of intent transitions.** Should the model enforce
   ritual-gated changes (e.g. "you can only move a task from `next` to
   `maybe` during a periodic session"), or allow ad-hoc edits anytime? The
   current FSM is lax; the reference FSM was strict.
4. **Lifecycle of `clarified=false` Inbox items.** Same row as Task or
   separate `InboxItem` entity? Affects future split/merge UX.
5. **Multiple FocusSessions per day.** Allowed? Probably yes — morning
   session, afternoon session — but UX implications for "rollover" need a
   pass.
6. **Migration plan.** Phased path from current FSM to proposed model. Not
   yet specified.

---

## 9. Things that are *decided* in this session

For the avoidance of doubt, the following positions came out of the
discussion as committed (subject to written-down rebuttal):

- The global Task FSM should be retired in favour of orthogonal decomposition
  — *unless* a future review favours going the other way (full FSM with
  `Focus` as state). The current half-and-half is the worst of both worlds.
- `FocusSession` and `PeriodicSession` are separate entities.
- `FocusSession.tasks` is locked at session start; only attributes mutate
  during the session.
- Rollover at session review is **explicit and per-task**, not automatic.
- Internal terminology drops "Daily" and "Evening" in favour of
  session-relative names; UI copy retains user-facing "today" / "this week"
  language (§10).

---

## 10. Terminology — internal vs. UI

The implementation today uses date-relative names ("Daily Planning Ritual",
"Evening Shutdown") that have leaked into code as date arithmetic. This
conflates *what* the ritual is (planning a focus session, reviewing it)
with *when* it happens (the user's morning, the user's evening). The
conflation drives bugs around day boundaries, planning-time configuration,
and timezone handling.

Rename the internal concepts to be session-relative:

| Today (internal)            | Proposed (internal)        | UI copy (unchanged)        |
|-----------------------------|----------------------------|----------------------------|
| Daily Planning Ritual / DPR | `focus_session_planning`   | "Plan today" / similar     |
| Evening Shutdown            | `focus_session_review`     | "Wrap up the day" / similar|

The PeriodicSession concept (§6.1) doesn't exist in code yet — it will be
born as part of #54 (Weekly Review wizard). That work should land with
`periodic_session_*` naming from day one; there's nothing to rename.

Side benefit: `focus_session_*` (now) and `periodic_session_*` (when #54
ships) make the §6.1 distinction structurally obvious in code.

---

## 11. Related issues

Backlog audit done 2026-04-25. Mapping of items from this proposal to the
issue tracker:

### Filed from this proposal

- **TMaYaD/Jeeves#181** — Polymorphic blockers *(epic)*. Task / Person /
  Time / Location variants, recurring windows, AND semantics, multiple
  simultaneous. To be domain-modelled and split into stories later.
- **TMaYaD/Jeeves#185** — `FocusSession` entity refactor. The load-bearing
  change. Retires the global Task FSM in favour of orthogonal decomposition.
- **TMaYaD/Jeeves#183** — Internal terminology rename (§10). Small
  standalone refactor, high-leverage, can land first.
- **TMaYaD/Jeeves#182** — TimeLog entity. Replace `time_spent_minutes`
  (imperative state mutated in `transitionState` side effects) with a
  `TimeLog` table where each in-progress interval is a row; total becomes
  a computed sum. Aligns with the proposed `Timer.intervals` design (§6).
- **TMaYaD/Jeeves#184** — Clarify & Organise rework. Future; one-to-many
  splits, many-to-one merges, possibly distinct `InboxItem` entity (§6.4).

### Already covered by existing issues

- **Periodic planning + retrospective** — TMaYaD/Jeeves#54 (Guided Weekly
  Review Wizard) covers both via its 5-step wizard with summary + objective
  setting.
- **Pause / Unpause focus timer** — relates to TMaYaD/Jeeves#47 (Pomodoro
  Sprint Timer), which is being delivered via TMaYaD/Jeeves#142 and lands
  independently. Pause/Unpause as a timer affordance is naturally a Pomodoro
  feature; no separate issue needed at this time.

### Superseded by TMaYaD/Jeeves#185 (FocusSession refactor)

- **TMaYaD/Jeeves#134** (Planning-day rollover: anchor "today" to planning
  time) — once `FocusSession` owns its own start/end timestamps, the entire
  `planningToday()` primitive disappears and the day-boundary bug class is
  structurally impossible. To be closed when TMaYaD/Jeeves#185 lands.

### On hold pending TMaYaD/Jeeves#185

- **PR TMaYaD/Jeeves#140** (Evening Shutdown — addresses
  TMaYaD/Jeeves#83) — was churning because the conceptual obscurity in
  the current state machine makes "Roll Over", "Return to Next Actions",
  and "Defer at Shutdown" require ritual-bypass DAO methods. The PR's
  churn was the trigger for this proposal, and the shutdown flow becomes
  structurally cleaner once Focus is a session, not a flag.

### Linked but separate tracks

- **TMaYaD/Jeeves#180** (Daily planning ritual UI/UX redesign) — UI/UX
  redesign track, separate from this domain-modelling proposal. The two
  intersect at the planning ritual surface but should not be conflated.
- **TMaYaD/Jeeves#47 / #142** (Pomodoro Sprint Timer) — proceeding
  independently of this proposal; delivers value irrespective of the
  underlying time-logging refactor. Pause/Unpause as a timer affordance
  is naturally a Pomodoro feature.

---

## 12. References

- Implementation:
  - State enum: `backend/app/todos/models.py:30`,
    `app/lib/models/todo.dart:9-18`
  - Transition rules: `app/lib/models/gtd_state_machine.dart:28-77`
  - Transition logic + side effects:
    `app/lib/database/daos/todo_dao.dart:212-300`
  - Ritual-bypass methods: `app/lib/database/daos/todo_dao.dart:375-610`
- Notes that informed this review:
  - `NOTES.md` 2026-04-21 — `inbox → scheduled` two-hop workaround.
  - `NOTES.md` 2026-04-22 — shutdown rollover bypassing the FSM.
- Memory:
  - `project_day_boundary` — day-rollover-time bug class that disappears
    once `FocusSession` owns its own time bounds.
- This document supersedes nothing yet; it is a proposal record.
