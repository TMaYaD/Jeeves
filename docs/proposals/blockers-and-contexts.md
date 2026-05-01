# Proposal: Blockers and Contexts

**Status:** Domain modelling complete, ready for engineering. Tracked under [#181](https://github.com/TMaYaD/Jeeves/issues/181).

**v1 children:** [#235](https://github.com/TMaYaD/Jeeves/issues/235) PersonBlocker · [#237](https://github.com/TMaYaD/Jeeves/issues/237) Re-clarification surface
**Punted (no current driver):** [#236](https://github.com/TMaYaD/Jeeves/issues/236) TaskBlocker
**Deferred (future phases):** [#238](https://github.com/TMaYaD/Jeeves/issues/238) TimeContext · [#239](https://github.com/TMaYaD/Jeeves/issues/239) LocationContext

## Problem

The current Todo model encodes "user wants to act, can't yet" via three FSM states (`waiting_for`, `scheduled`, `blocked`) plus side fields. This collapses a polymorphic concern into a single state field that holds at most one blocker at a time. Real Tasks have multiple, heterogeneous obstacles:

- "Send proposal" is blocked by **Trixy replying** AND by **Wednesday's call** happening first.
- "Renew lease" is blocked by **time** ("after Nov 30") AND by **needing the landlord's email**.
- "Fix garage door" is constrained by **location** ("at home") AND by **time-window** ("daylight hours").

The original framing (#181 v1) called all of these "polymorphic blockers." Modelling pulled them apart into two distinct concepts.

## The core distinction: Blockers vs Contexts

The original framing conflated two genuinely different things. They have different attachment points, different temporal shapes, and different relationships to action.

|                       | **Blocker**                                | **Context**                                       |
|-----------------------|--------------------------------------------|---------------------------------------------------|
| Attaches to           | Task (the outcome)                         | NextAction (the act)                              |
| Describes             | Outside-the-user state relevant to outcome | Predicate on whether *now* is a moment to act     |
| Temporal shape        | Event (it clears at a moment)              | Predicate (true or false at any given moment)     |
| Relationship to action| Coexists — user can act *alongside* the wait | Gates visibility of the action                  |
| Example               | "Waiting on Trixy to reply"                | "Trixy is only reachable 9–5"                     |

Both can coexist on the same Task simultaneously, attached to different entities. The pinning example: *"Follow up with Trixy (Blocker on Task), but she is only available 9–5 (Context on NextAction)."*

### Why outcome-vs-action matters here

The split mirrors a deeper design tenet: **the Task is the persistent outcome; the NextAction is the moving part.** Blockers describe state relevant to the outcome (they live where the outcome lives). Contexts describe constraints on the act (they live where the act lives). Conflating them produces models that drift — e.g. modelling "after Nov 30" as a Task-level Blocker forces the outcome itself to be in some "blocked" state, when really the outcome is fine and only one possible action against it is gated.

## Variants

### Blockers (v1)

**PersonBlocker** ([#235](https://github.com/TMaYaD/Jeeves/issues/235)) — outside-the-user wait on a person.

- **No separate entity.** PersonBlocker collapses into `TodoTag(type='person')`. The existence of a person-typed tag link on a Task *is* the wait.
- The `Tag.type` CHECK constraint expands to `IN ('context', 'project', 'area', 'label', 'person')`.
- Clearing = TodoTag row deletion. No stored `cleared_at`, no history. The Phase 4 history use cases (auto-clear detection, "what waits did I resolve last week," wait-duration analytics) are deferred — they'll be served by a future event-log mechanism, not by mining blocker rows. YAGNI for v1.
- "What am I waiting on Trixy for?" = `Tasks ⨝ TodoTags ⨝ Tags WHERE Tag.type='person' AND Tag.id=trixy_id`. Falls out for free, no new join table.
- Notes about *what* you're waiting for ("review of Tuesday's proposal") live in Task description — there's no separate UX surface for blocker-notes that wouldn't render right next to it anyway.
- Reuses Tag infrastructure end-to-end: identity, sync, cross-Task query, spelling-variant resolution, typeahead UI.

**v1 UX shape** (full detail in [#235](https://github.com/TMaYaD/Jeeves/issues/235)):

- Task detail carries a single derived **status row** that reads `Next` / `Waiting For Trixy & Capo` / `Someday` / `Done` / `Trashed`. Status is a downstream view of (long-term-state, person-tags), not a separate persisted enum.
- The status menu is the *only* path to add/remove person-tags. The general tag picker excludes `type='person'`. To go from `Waiting For` to `Next`, the user clears the person-tags via the same picker.
- A new **Waiting List** view groups Tasks by person — same Task appears under every person it's waiting on. Reuses the Next-list item template per row.
- Adding/removing a person-tag stamps `Task.last_clarified_at`; adding/removing organising-type tags does not (Tag-type-aware clarify-stamping — see *Clarify vs organise* below).

**Why this collapse is safe.** The originally proposed separate `PersonBlocker` table was justified by `cleared_at` history, a `notes` field, and conflation prevention against "person-as-organising-tag." Each dissolved on inspection: history is Phase 4; notes have no UX home distinct from Task description; "person on Task" has no plausible non-blocker meaning. The unifying abstraction is the `isBlocked(task)` predicate, not the storage.

The door is left ajar: an explicit `PersonBlocker` entity may be revisited later if a more compelling use case emerges than the ones already considered. Until then, the tag-shaped form is load-bearing.

### Punted: TaskBlocker

**TaskBlocker** ([#236](https://github.com/TMaYaD/Jeeves/issues/236), closed) — Task A blocks Task B until A is done. **Punted entirely** from v1 until a real driver emerges.

The shape was designed (live-predicate `cleared = blocking_task.done_at IS NOT NULL`, create-time cycle prevention, cascade-on-trash flagging dependents for re-clarification) and could be implemented when needed. But:

- No user is currently asking for it. PersonBlocker covers the load-bearing v1 use case.
- PersonBlocker collapsed all the way to `TodoTag(type='person')` with no entity at all. Building a separate `task_blockers` table for a use case nobody is pulling on is YAGNI.
- The TaskBlocker UX was already deferred from v1 (plumbing-only). Without a UX consumer, the plumbing has no caller.
- Re-clarification surface ([#237](https://github.com/TMaYaD/Jeeves/issues/237)) can be specified without TaskBlocker re-engagement / trashed-cascade as inputs to its `latest_relevant_state_change`.

If someone (the user or otherwise) eventually hits a workflow where "Task A blocks Task B" is genuinely the right shape — and not better served by editing Task B's outcome description or cursor — the design above is the starting point. Reopen #236 then.

### Contexts (deferred)

**TimeContext** ([#238](https://github.com/TMaYaD/Jeeves/issues/238)) — `now ∈ <set of intervals>`.

- One concept covers both "after Nov 30" (open-ended interval `[Nov 30, ∞)`) and "Tue/Thu 9–5" (recurring set of intervals). Different interval shapes, same predicate.
- Reclassified from the original `TimeBlocker(specific)` — it's predicate-shaped, not event-shaped.

**LocationContext** ([#239](https://github.com/TMaYaD/Jeeves/issues/239)) — predicate on user's current location.

- Depends on geofencing / OS hooks. Naturally Phase 3 territory.
- Coordinates with existing `location_id` field on Todo and design epic [#46](https://github.com/TMaYaD/Jeeves/issues/46).

### Why Contexts are entirely deferred from v1

- v1 ships Blocker plumbing without UI for action-level gating. Contexts need a NextAction-level visibility-gating UX surface that doesn't exist yet.
- The "after Nov 30" use case is handled in v1 as freeform Task notes — the user re-clarifies the right NextAction when the time arrives. Cheap workaround until structured Contexts land.
- Existing `Tag(type='context')` rows ("@call", "@home") stay untouched in v1. They get a migration story when Contexts land — converted to TimeContexts / LocationContexts where they fit, retired where they don't.

## Scope and sequencing

- **v1 UX is throwaway** ("jugaad"). Each v1 child ships minimal placeholder UX sufficient to exercise the plumbing. Formal blocker UX lands in [#180](https://github.com/TMaYaD/Jeeves/issues/180)'s ritual redesign, which sits on top of stable plumbing.
- **Variants are sequenced one-at-a-time**, not bundled. Each Blocker / Context variant gets its own consideration pass and its own PR sequence. PersonBlocker and the re-clarification surface are the v1 pair; TaskBlocker is punted; TimeContext and LocationContext are deferred placeholders.
- **TaskBlocker is punted, not deferred.** No current driver — nobody is asking for cross-Task dependency tracking, and PersonBlocker covers the load-bearing v1 case. Reopen [#236](https://github.com/TMaYaD/Jeeves/issues/236) when a real workflow hits the wall without it.

## Time pre-conditions vs deadlines

The original epic silently conflated these. They are different.

- **"By Nov 30"** = deadline = property of the **outcome**. Lives on Task. Already exists today as `due_date`.
- **"After Nov 30"** = pre-condition = property of an **action**. Future TimeContext on NextAction.

v1 doesn't add structured "after Nov 30" support — that's TimeContext territory ([#238](https://github.com/TMaYaD/Jeeves/issues/238)).

## Adjacent decisions

The interview surfaced several decisions adjacent to Blockers/Contexts that shaped the model.

### Outcome-over-action is a core tenet

The Task is the persistent outcome. The NextAction is whatever moves the outcome forward right now. This is not a modelling convenience — it's the design language Jeeves enforces:

- "Done" means outcome achieved, not next-action completed. Completing a NextAction triggers re-clarification ("what's the new next action?"); it does not mark the Task done.
- The system prompts "what's next?" — the user doesn't manually re-create entities each time.
- **The system does not spawn tasks from tasks.** The Task persists; only the NextAction evolves. Multi-step back-and-forth (send → wait → review → revise → wait again) lives entirely within one Task's lifetime.
- Task titles drift toward outcome-language. One-shot tasks ("buy milk") collapse — action and outcome are the same. Multi-step tasks need outcome-language ("get document reviewed by Trixy") so the persistent thing has the right name.
- AI features (Phase 4) plug into this tenet: auto-follow-up, auto-delegate, auto-detect-stalled-outcome are all expressions of the system supercharging the user's outcome-tracking.

### NextAction is a lightweight cursor

NextAction is **not** an entity with its own lifecycle. Conceptually:

- Current NextAction = a text field on Task pointing to "what would I do next."
- Past NextActions = history log entries (e.g. on the existing TimeLog).
- Future thoughts = freeform notes / bullet lists in Task description.

No state machine, no `created → done | abandoned` transitions, no successor invariants. "Completing" = the cursor moves on. "Abandoning the approach" = user replaces the cursor text; the discarded approach lives in the log.

A Task may have **zero** current NextActions (just captured, or just completed and awaiting re-clarification). "Has a current NextAction" and "needs clarification" are independent axes.

### No planned-action entities

A Task has at most one current NextAction plus a history. There are no `plannedNextActions[]`, ordered queues, or "next-after-current" pointers. Future-action thoughts go into freeform notes — the GTD need ("don't leave thoughts in the head") is met without inviting waterfall planning, dependency graphs, or cross-action invariants.

### Task long-term states

Four states: `active`, `someday`, `done`, `trashed`.

- **`active`** — on the radar, eligible for any day's plan.
- **`someday`** — Maybe/Someday bucket. Still wanted, surfaces in normal review cadence.
- **`done`** — outcome achieved. Reversible by field-flip.
- **`trashed`** — outcome forever given up. Reversible by field-flip. The only state that cascades to TaskBlocker dependents.

There is no long-term `abandoned` state.

### Daily plan immutability and evening shutdown

The daily plan is immutable by design — once locked in for today, the user doesn't reshuffle it. Mid-day, if the user stops working on a Task, it becomes **visually demoted** within today's plan (still `active`, just marked "set aside today").

At evening shutdown, every demoted Task is **force-resolved** to one of:

- **Rollover** — auto-includes in tomorrow's plan.
- **Back to Next** — stays `active` but off plan.
- **Maybe/Someday** — state transitions to `someday`.

The user does not carry unresolved demoted Tasks across days.

### Tags attach to Task only

Tags continue to attach to Task, not NextAction. The existing `Tag.type` set extends to include `'person'`; everything else stays put.

- **Project / area / label Tags** are organising the *outcome*. They belong on Task by definition.
- **`Tag(type='person')`** is the load-bearing v1 blocker shape (see PersonBlocker above). Attaching a person-tag to a Task means "waiting on this person" — there is no organising-only meaning for person tags.
- **`Tag(type='context')`** ("@call", "@home") was historically Task-attached. Conceptually it belongs on NextAction (it constrains the *act*) — that's TimeContext / LocationContext territory in v2. v1 leaves the existing rows alone; the migration story lands when Contexts do.
- **At-most-one current NextAction per Task** means Task-level tags effectively cover action-level tagging without information loss in v1. A future refactor (per-action tags) only makes sense if a concrete use case demands it.
- **Tag changes are organising, not clarifying** — they don't stamp `last_clarified_at` (see below).

### Clarify vs organise

Two distinct user activities:

- **Clarifying** — answering "what does this outcome need from me?" (set/edit outcome, swap NextAction, add/remove Blocker, set due-date, explicit "still good" confirmation).
- **Organising** — sorting/filing the Task into structure (tagging, future Context-assignment).

Only clarifying stamps `last_clarified_at`. Organising does not. Conflating them would make `last_clarified_at` jittery (every drag-into-project resets the clock) and dilute the re-clarification signal.

Because PersonBlocker rides on Tag infrastructure, the rule is *Tag-type-aware*: adding/removing a `Tag(type='person')` link IS clarifying (it's a Blocker change) and stamps `last_clarified_at`. Adding/removing organising-type tags (`project`, `area`, `label`, `context`) does not. The discriminator is `Tag.type`.

### Inline clarify is offered, never required

Completion and re-clarification are decoupled even in the happy path. The prime moment to ask "did you achieve your outcome? if not, what's next?" is at NextAction completion in a focus session — but **forcing** it on every completion would make list-knockdown flows (e.g. grocery items) feel like 20-questions and annoying. The user must always be able to complete-and-defer; the Task lands in the re-clarify queue without friction at point of completion.

## The re-clarification surface

[#237](https://github.com/TMaYaD/Jeeves/issues/237) is the integration point that turns Blocker plumbing into something the user actually sees during planning.

### `last_clarified_at` on Task

A timestamp updated by clarifying actions. Stamps on:

- Task creation (the act of giving a Task a title/outcome *is* light clarification).
- NextAction cursor edit (create or swap).
- Add/remove Blocker (any variant).
- Edit title or outcome description.
- Change due-date.
- Explicit "still good" confirmation during planning.

Does **not** stamp on:

- Tag changes (organising, not clarifying).
- Freeform notes edits.
- Upstream events (PersonBlocker auto-cleared, blocking Task transitioning).
- NextAction completion (this is the *trigger* for needing re-clarification, not an act of clarifying).

### Derived predicates

The original epic claimed a single `actionable` predicate gating on Blockers. Modelling decomposed this into **three independent dimensions** — Blockers don't gate actionability, they describe state.

1. **`hasNextAction(task)`** — does the Task have a current NextAction (cursor non-empty)? The clarify status: has the user thought about it enough to commit to a next move?
2. **`isDoableNow(nextAction)`** — are all of this NextAction's Contexts satisfied right now? The context check: am I in the right place / time to do this? Empty Context list ⇒ trivially doable. (v1: trivially true since Contexts are deferred.)
3. **`isBlocked(task)`** — does this Task have any unresolved Blockers? The descriptive state, orthogonal to whether a NextAction exists. (v1: equivalent to "has any `Tag(type='person')` link," since PersonBlocker is the only Blocker variant.)

The four-quadrant matrix has different planning-ritual roles:

|                  | unblocked                                                      | blocked                                                            |
|------------------|----------------------------------------------------------------|--------------------------------------------------------------------|
| **has NextAction** | classic "ready to act" — pick from these for today             | acting against / around the block (follow up, escalate, prep)      |
| **no NextAction**  | needs clarification *now* — outcome can move, no action defined | passive wait — surface in Weekly Review ("escalate or accept?")     |

For surfacing Tasks for attention, two further derived predicates compose from the dimensions:

- **Stale**: `last_clarified_at < latest_relevant_state_change`, where the latter is NextAction-cursor-was-completed in v1. (PersonBlocker add/remove stamps `last_clarified_at` directly — no separate timestamp to compare against. TaskBlocker is punted, so its re-engagement and trashed-cascade inputs don't apply.)
- **Actionless**: same as `¬hasNextAction(task)` for non-terminal Tasks.

A Task can be stale, actionless, both, or neither. Implementation may stage or denormalise as needed for query performance — the *contract* is the derivation.

### Same prompt, three surfaces

The re-clarification question — *"did you achieve your outcome? if not, what's the next action?"* — appears in three places, all consuming the same predicate:

1. **Inline at NextAction completion** in a focus session (the lightest, most contextual moment — but offered, never required).
2. **Daily Planning re-clarify queue** for Tasks that didn't get inline-clarified (the bulk surface).
3. **Phase 4 AI nudge** at low-friction moments (the eventual smart surface).

Designing for the predicate, not the surface, means all three flow from one source of truth.

### Why timestamp + derived predicate, not a stored boolean

- **Single source of truth.** The blocker/action state changes are already authoritative. A `needs_review` boolean would be a derived fact stored separately — it can drift, get flipped wrongly, race between sync clients.
- **Multiple predicates fall out for free.** Stale Tasks, freshly-blocked Tasks, ready-for-planning Tasks all compose from the same timestamp.
- **AI-ready (Phase 4).** "Tasks Jeeves should nudge about" needs the freshness signal anyway.
- **Cheap.** One nullable timestamp on Task. No cascade-write logic on every state change.
- **Honors outcome-over-action.** Re-clarification is a property of the Task (the persistent outcome), not derived from a flag tossed around between subordinate entities.

## Out of scope

- The Daily Planning ritual redesign (owned by [#180](https://github.com/TMaYaD/Jeeves/issues/180)).
- The `intent` enum, FSM retirement, FocusSession refactor (covered separately).
- A first-class Project entity (separate decision).
- Backfill from existing free-text `waiting_for` field on Todo — design pass needed; not blocking v1 plumbing.
- AI-driven nudges and auto-clarification (Phase 4).

## References

- [#181](https://github.com/TMaYaD/Jeeves/issues/181) — parent epic (modelling synthesis).
- [#180](https://github.com/TMaYaD/Jeeves/issues/180) — Daily Planning ritual redesign (consumes this plumbing).
- [#46](https://github.com/TMaYaD/Jeeves/issues/46) — Contextual & Geofenced Surfacing (LocationContext dependency).
- [#34](https://github.com/TMaYaD/Jeeves/issues/34) — GTD Inventory Engine (sequential dependencies).
- [#38](https://github.com/TMaYaD/Jeeves/issues/38) — closed; first cut at `blocked_by_todo_id` (now retired).
