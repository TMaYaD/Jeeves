<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Jeeves

Jeeves is an opinionated, offline-first, AI-augmented Getting Things Done (GTD) productivity app. This glossary defines the vocabulary of the system across its bounded contexts (GTD Core, Engagement, Ceremony Framework, Sync, AI Augmentation — codified as each is grilled).

The glossary is organised into two top-level tiers:

- **Conceptual** — the user's mental model. Concepts that would exist in a physical GTD system on paper, regardless of how (or whether) they are implemented. The user's world view is authoritative here.
- **Implementation** — code-level abstractions that live in the code: storage shapes, UI/UX patterns, protocols. No physical-world counterpart from the user's perspective; the user sees Outcomes and Ceremonies, not Tags and Wizards. These names exist because the implementation needs them, not because the user thinks about them.

Within each tier, terms are nested by bounded context only when the context's vocabulary has grown large enough that grouping helps navigation. Implementation often organises differently than concept — its splits follow storage and code-module boundaries, which need not mirror the conceptual contexts.

**Term unification between model and user-facing copy.** Identifiers in code and labels in UI copy should use the same term wherever possible — divergence creates friction for both contributors (mental translation reading code) and users (mental translation reading docs). Any divergence requires:

1. A specific reason — typically cadence-flavour (a generic state name rendered with the period's name in copy), GTD-vernacular preservation (a UI label that matches the user's known terminology), or accessibility.
2. An unambiguous mapping documented in the relevant term's definition or Flagged ambiguities.

The current known divergences:

- **Next** (domain) is rendered as "Next Action" in UI copy when referring to the current-role Action of an Outcome on the Next List.
- A FocusSession's **Plan** (domain) is rendered with cadence-flavoured copy ("Today's Plan" at the daily cadence).
- A Nudge's `dismissed` / `completed` states (domain) are rendered with cadence-flavoured copy ("Not today" / "Not this week" / etc.) in Banner and Notification surfaces.
- **Focus** (domain — the FocusSession's execution home screen) is rendered as **"Now"** in UI copy. "Now" answers *what am I doing?* alongside Next (*what could I do?*) and Someday/Maybe (*what might I do eventually?*); internal identifiers stay Focus / FocusSession, and the cadence remains daily by default. (Ruled in the epic #35 design review — see the decision comments on TMaYaD/Jeeves#35.)

**New surfaces lead the rename.** Where UI copy and canonical vocabulary have drifted (e.g. legacy "Next Actions" / "Maybe" labels), every *new* surface uses the canonical term regardless of what neighbouring legacy surfaces still display; legacy surfaces catch up later. Divergence within the app between new-correct and old-retired labels is an accepted transitional state, not a reason to propagate retired terms.

Prospective renames considered and **deferred**, pending legacy cleanup:

- **Action → Task** — currently rejected because "Task" is burned by inconsistent past usage (`task_id` columns referencing what we now call Outcome; architecture docs mixing "task" with "todo"). Reverting would re-conflate three concepts. Reconsider once the legacy is cleaned up and parity is achievable without re-conflating with retired meanings.
- **Outcome → Project** — currently rejected because "Project" is the derived classification per ADR-0003 (an Outcome with multiple Actions), and Allen's canonical GTD definition would collide with single-Action items being called Projects. Reconsider only if the ADR-0003 distinction is itself revisited.

## Conceptual

### GTD Core

#### Language

**Capture**:
A raw, unprocessed fragment the user has put into the system because it has their attention. Pending clarification; not yet an Outcome or Action. A Capture's clarification is its terminal act, recorded once as `clarified_at` — stamped when the user completes the clarify act for that Capture, whether it produced new Outcomes, merged into existing ones, or was discarded (a zero-Outcome clarification is a legitimate verdict, not a special case). An unstamped Capture sits in the Inbox; a stamped one persists as provenance for the Outcomes it clarified into — Captures are never deleted and merge never consumes them.
_Avoid_: Todo, Task, Item, Inbox item, Thought, Stuff, Note

**Outcome**:
A desired result the user is committed to achieving. The product of clarifying one or more Captures. An Outcome carries any number of Actions over its lifetime (current, planned, terminated).
_Avoid_: Todo, Task, Goal

**Project** *(derived classification)*:
An Outcome that requires more than one Action over its lifetime — David Allen's GTD canonical "Project" (a multi-step outcome). Not a separate entity; derived from the existence of more than one Action against the Outcome. The system does not surface "Project" as a distinct type — the same Outcome shape carries both single-Action items and multi-Action projects.
_Avoid_: Initiative, Umbrella, ProjectGroup (these would imply structural composition the model does not have)

**Action**:
A physical, visible activity that moves an Outcome forward. A first-class entity with its own identity and lifecycle, distinct from the Outcome it belongs to. An Action carries one of four roles at any time:

- `planned` — captured as part of the user's externalised thinking about the Outcome, but not yet eligible to be acted on. Multiple `planned` Actions may exist for one Outcome.
- `current` — the single Action eligible for engagement right now. Surfaced to the user as the GTD "Next Action."
- `done` — completed by the user (stamps `done_at`).
- `superseded` — replaced before completion (stamps `superseded_at`, optionally links to its replacement via `superseded_by_id`).

Terminated Actions (`done` or `superseded`) stay attached to their Outcome — the chain of Actions over time is the Outcome's history.
_Avoid_: Task (when referring to the action), Step, TodoStep, Subtask, Cursor, NextAction (provisional code name — see ambiguities)

**Intent**:
The user's *willingness* to pursue an Outcome. One of `next` (yes, soon), `maybe` (yes, eventually), or `trash` (no, never). Intent is a stance, not a fact about completion.
_Avoid_: State, Status, Disposition (in this context)

**Completion**:
The fact that an Outcome has been achieved, recorded as a timestamp. Orthogonal to Intent — a user can change Intent on an unachieved Outcome without affecting Completion, and Completion happens to an Outcome regardless of Intent.
_Avoid_: Done state, Done intent

**Person**:
A person the user knows, interacts with, or depends on. Identified by a user-chosen name. A first-class concept independent of any particular Blocker or Outcome — the same Person can be referenced from many Outcomes' PersonBlockers, and from Action text ("call Trixy") regardless of blocking state.
_Avoid_: Contact, User (User is reserved for the app's owner), Collaborator

**Area** *(of Focus)*:
A domain of recurring responsibility — David Allen's GTD horizon-2 concept. Examples: "Health", "Finance", "Family", "Open-source maintenance." An Area is a permanent (or long-lived) categorisation; Outcomes belong to zero or more Areas.
_Avoid_: Category, Topic, Project (Project is structural; Area is responsibility-domain)

**Label**:
A user-defined granular grouping. Jeeves-specific extension — not GTD canon — to let users categorise Outcomes more finely than Areas, or cut across Areas (e.g. "urgent-this-week" may span Health and Finance). Free-form; the user creates and retires Labels as needed.
_Avoid_: Tag (Tag is the storage shape, not the concept), Bucket

**Blocker**:
Outside-the-user world-state relevant to an Outcome that is unresolved. Attaches to the Outcome (it describes the outcome's situation), and *coexists* with the Outcome's current Action — having a Blocker does not preclude having a current Action, and the current Action may be the very thing that resolves the Blocker.
_Avoid_: Block, Dependency, Constraint (Constraint is reserved for action-level predicates — see Context)

**PersonBlocker**:
A Blocker whose unresolved world-state is "this Person has not yet acted." References a specific **Person**; existence of the reference is the wait, removal is its resolution. The user-visible list grouping Outcomes-by-Person is called **Waiting For**.
_Avoid_: WaitingFor (as an entity name), Wait, PendingPerson

**Context** *(deferred — not yet modelled)*:
A predicate over current world state ("is *now* a moment when this action is doable?") that attaches to an Action and gates its visibility. Distinct from a Blocker: a Blocker describes outside-the-user state relevant to the *outcome*; a Context gates *whether you can act*. Examples: "@phone" (action is doable when phone is available), "after Nov 30" (action is doable from that date).
_Avoid_: Constraint, Filter, Gate

**Hard landscape** *(deferred — not yet modelled)*:
GTD's "sacred territory": the commitments that are genuinely time-bound with real consequences if missed — the only things that belong on a calendar (time-specific and day-specific commitments). Distinct from a due date (which may be aspirational) and from a **Timebox** (a session-scoped intention — see Engagement). What marks an Outcome as hard-landscape is an open modelling question owned by #410; the term is reserved now so timeboxes and soft due dates are never described as calendar-worthy.
_Avoid_: Deadline (may be aspirational), Appointment (narrower), Event (reserved for external-calendar entries)

**Clarification**:
The act of thinking about an Outcome (or a Capture in its first such act) and committing the result to the system. Manifests as a *stream of micro-acts* — each individual write that constitutes structural thinking-about-the-Outcome stamps `Outcome.last_clarified_at`. There is no "clarification session" entity; the UI may wrap micro-acts in a session-shaped flow but the domain commits each write independently. Distinct from **Engagement** (doing the current Action — does not stamp) and from **Organising** (sorting into structure via organising-type tags — does not stamp).
_Avoid_: Review, Refresh, Process (Process is the GTD verb but overloaded with UI / queue / batch meanings)

**Organising**:
The act of placing an Outcome into the user's organisational structure — adding or removing **Area** memberships, **Label** assignments, or any future purely-categorisation linkages. Changes *where* an Outcome belongs without changing *what* it is or what's happening to it. The third sibling alongside **Clarification** (thinking about the Outcome — stamps `last_clarified_at`) and **Engagement** (doing the current Action — produces TimeLogs); Organising neither stamps nor logs. Note: PersonBlocker add/remove looks like Organising at the storage level (it's a Tag link) but is conceptually Clarification, since PersonBlocker is a Blocker on the Outcome, not a categorisation.
_Avoid_: Categorising (narrower — covers only one mode of Organising), Filing, Tagging (Tag is the storage mechanism, not the act)

**Stale** *(derived predicate)*:
An Outcome whose `last_clarified_at < last_action_completion_at` — the current Action has terminated since the user last thought about the Outcome. The strongest "pick this up next clarification" signal.

**Actionless** *(derived predicate)*:
An Outcome with no current Action. May still have planned Actions (the user has externalised thinking but not committed to engagement) or none (planless).

**Planless** *(derived predicate)*:
An Outcome with no current Action **and** no planned Actions. The Outcome exists but the user has not externalised any "what's next." The strongest needs-attention signal among non-terminal Outcomes.

**List**:
A named collection of items. A List may be **explicit** — its membership is stored (e.g., the planned Actions of an Outcome, the task membership of a Focus Session) — or **implicit** — its membership is a derived query/filter applied to the system's entities (e.g., the GTD lists below, the Outcomes in an Area). The explicit/implicit split affects storage and ordering semantics but not the conceptual role. List exists as a first-class concept across every tier of the system: the model has explicit Lists as relations, the protocol serves Lists as collection endpoints, the UI renders every multi-item view as a List, the user *thinks* about their work in Lists. Anywhere a developer is tempted to invent a new "collection of X" abstraction, the question to ask first is *which kind of List is this?*
_Avoid_: Collection, View, Bucket, Queue (Queue implies FIFO, which Lists do not require)

**Inbox**:
The implicit List of Captures pending clarification (`clarified_at` is null). The user's trusted bucket for unprocessed stuff.
_Avoid_: Capture queue, Capture List

**Next**:
The implicit List of Outcomes the user is willing to handle next. Defined by:

```text
Intent = next ∧ clarified ∧ Completion is null ∧ (has current Action ∨ no PersonBlocker)
```

The user engages with the row's *current Action* — but the List contains Outcomes, not Actions. The single excluded quadrant is **actionless AND PersonBlocked**: an Outcome with no current Action that is waiting on a Person is a pure wait and surfaces only on Waiting For, not on the daily Next List (its cadence belongs to the weekly Waiting For pass). An Outcome with a current Action belongs on Next regardless of any PersonBlocker — per the Blocker definition above, the current Action coexists with the Blocker and is doable: `"call Trixy for a follow up"` is engageable while the Outcome is waiting on Trixy, and such an Outcome appears on Next *and* under Waiting For simultaneously.
_Avoid_: Next Actions (the list is of Outcomes, not Actions — though "Next Action" remains the user-facing label for the role of the row's current Action), Todo, Ready

**Waiting For**:
The implicit List of Outcomes that are PersonBlocked, grouped by the blocking Person. An Outcome blocked on multiple Persons appears under each Person it is blocked on. **Overlaps with Next when the Outcome has a current Action**: such an Outcome appears on Next (the Action is doable) *and* under Waiting For (the dependency is real). The overlap is by design — it surfaces "I can do this *while* waiting" without losing either fact. An actionless PersonBlocked Outcome appears here only — it is excluded from Next by the rule above.
_Avoid_: Waiting, Blocked, Pending

**Someday/Maybe**:
The implicit List of Outcomes the user has deferred. Defined by: `Intent = maybe`, `Completion is null`.
_Avoid_: Maybe, Later, Backlog

**Done**:
The implicit List of completed Outcomes the user still considers part of their record. Defined by: `Completion is not null` AND `Intent != trash`. A trashed-and-completed Outcome surfaces in **Trash**, not Done — the user's stance to discard takes precedence over the historical Completion fact, so Done and Trash stay disjoint.
_Avoid_: Completed, Finished, Archive (Archive implies removal from active concerns; Done is just the achieved set)

**Trash**:
The implicit List of Outcomes the user has discarded. Defined by: `Intent = trash` (regardless of Completion). User-facing surface deferred.
_Avoid_: Deleted, Removed (the row persists; Intent expresses the user's stance)

#### Relationships

- A **Capture** is many-to-many with **Outcome**: one Capture may clarify to zero, one, or several Outcomes; one Outcome may trace back to several Captures (duplicate or complementary fragments merged during clarification).
- The clarify UX runs in one of two user-selectable modes — a preference over the same many-to-many model, never a storage change. In **1-1 mode** each Capture clarifies to exactly one Outcome and `clarified_at` stamps automatically at the first Outcome link; in **n-m mode** (split/merge) the user explicitly completes each Capture, and only that completion stamps `clarified_at` — a Capture stays in the Inbox while Outcomes are incrementally carved out of it.
- An **Outcome** has at most one *current* **Action** at any time, may have any number of *planned* Actions (the user's externalised "what's next" thinking), and has 0..N *terminated* Actions (done or superseded) over its lifetime.
- An **Outcome** that ends up needing multiple Actions is colloquially a *project* — no separate type is required.
- An **Outcome** carries an **Intent** (the user's willingness) and may carry a **Completion** timestamp (the fact of achievement); the two axes are independent.
- An **Outcome** may have any number of **Blockers** that *coexist* with its current **Action**. The classic case: a PersonBlocker "waiting on Trixy" lives on the Outcome while the current Action reads "follow up with Trixy." Acting on the current Action is what *might* resolve the Blocker; the two are not in opposition.
- An **Action** belongs to exactly one **Outcome**. Captures reach Actions only indirectly, through the Outcomes they clarify to.
- An **Outcome** is categorised into zero or more **Areas** (M:N) and labelled with zero or more **Labels** (M:N).
- A **PersonBlocker** references exactly one **Person**; one Outcome may have multiple PersonBlockers (waiting on multiple Persons), and one Person may be the subject of PersonBlockers on multiple Outcomes.
- A **Person** may also appear in Action text or Outcome notes without being a Blocker — referencing a Person does not imply blocking on them.
- An **Action** may have zero or more **Contexts** (M:N) — deferred but conceptually committed; the relationship is owned by Action, not Outcome.
- **Only the *current* Action is engageable.** Planned Actions cannot have TimeLogs, do not surface in **Next** / Focus Mode / Today's Plan. They are visible only in the context of their Outcome (where the Outcome's plan — an explicit List of planned Actions — is shown).
- **Promotion from `planned` to `current` is an explicit clarifying act, never automatic.** When the current Action terminates, the Outcome enters the "no current Action" state until the user re-clarifies and either promotes a planned Action, edits one, or creates a new one.
- **The plan carries no explicit dependencies.** Ordering among planned Actions is the user's intuition about sequence, not a DAG. The user revises ordering during clarification.
- **TimeLog** records are attributed to an Action (not an Outcome) — you log time against the specific *action being performed*. An Outcome's total time invested is summed from the TimeLogs of its current and past Actions.
- **Clarification stamps `last_clarified_at` per micro-act.** The principle: a write stamps iff it constitutes thinking-about-the-Outcome. Stamping writes include Outcome creation; title/notes/Intent/due-date edits; any Action mutation (create, edit, supersede, promote, demote, reorder, remove); Blocker add/remove (including PersonBlocker, however stored); explicit "still relevant" confirmation; Outcome completion or trashing. Non-stamping writes include current Action completion (engagement signal, not clarification), TimeLog writes, and Area / Label changes (organising).
- **The three Freshness predicates compose freely.** An Outcome may be {Stale + has-current-Action}, {Actionless but with planned Actions}, {Planless and Stale}, etc. Different review surfaces emphasise different combinations — Daily Planning's re-clarify queue surfaces *Stale ∨ Actionless*; a future "abandoned Outcomes" surface might emphasise *Planless ∧ ¬Stale-but-old* (never thought about much, never planned). The predicates are the contract; the surfaces are downstream.
- **GTD List membership is defined by filter, not by an "ownership" column** — the Lists are implicit projections, so an Outcome's membership in each is decided independently by that List's predicate. Most pairs are disjoint by construction: `Intent` (`next` / `maybe` / `trash`) partitions Next, Someday/Maybe, and Trash; `Completion` separates Done from the active set; Inbox is over Captures so does not overlap with any Outcome-bearing list. The single deliberate overlap is **Next ∩ Waiting For**, and it is conditional on having a current Action: an *actionable* PersonBlocked Outcome (`next_action_text IS NOT NULL`) appears on both — Next because the Action is doable, Waiting For because the dependency is real. An *actionless* PersonBlocked Outcome appears on Waiting For only; the Next List filter excludes it (see Next's definition). The Weekly Review wizard's Next-step snapshot applies a stricter per-step person-tag exclusion to keep its wizard steps disjoint; that is a wizard concern, not the everyday Next List rule.

#### Example dialogue

> **Dev:** "If the user dictates 'remind me to call John' into the inbox, is that an Action?"
> **Domain expert:** "It's a Capture. During clarification it becomes an Outcome — 'Catch up with John' — whose current Action is 'call John'. The Capture is the raw input; clarification produces the structure."
>
> **Dev:** "When the user finishes the current Action, is the Outcome automatically done?"
> **Domain expert:** "Only if that Action was the last one needed. Otherwise the Outcome enters the no-current-Action state, and the user re-clarifies — possibly by promoting a planned Action."
>
> **Dev:** "If the user types three planned Actions during clarification but doesn't promote any, what's the Outcome's status?"
> **Domain expert:** "It has three planned Actions and no current Action. The Outcome is on the radar but nothing is engageable yet. The user has externalised their thinking — the next clarification is where one gets promoted."
>
> **Dev:** "How can an Outcome have a Blocker *and* a current Action at the same time? Isn't a block the absence of a doable action?"
> **Domain expert:** "No. The Blocker is on the Outcome — the outcome is waiting on Trixy. The current Action is 'follow up with Trixy' — something the user can do *while waiting*, that might even resolve the Blocker. Acting and waiting coexist."
>
> **Dev:** "So where does this Outcome show up — on Next, or on Waiting For?"
> **Domain expert:** "Both. The Lists are projections — they overlap when both predicates apply. Next picks it up because `Intent = next` and there is a current Action; Waiting For picks it up because the PersonBlocker is real. The overlap is conditional on having a current Action — strip the Action and the Outcome becomes a pure wait, which surfaces on Waiting For only. That's the single excluded quadrant from Next: actionless AND PersonBlocked."
>
> **Dev:** "If I move an Outcome to Someday/Maybe and then mark it done later, what was its Intent during the gap?"
> **Domain expert:** "`maybe`. Intent is willingness — the user was willing to do it eventually. Completion is what happened. They're independent axes; the gap isn't a contradiction."
>
> **Dev:** "If the user finishes the current Action in a Focus session, does that stamp `last_clarified_at`?"
> **Domain expert:** "No. Completion of an Action is engagement, not clarification. It's the *signal* that re-clarification is now needed — the Outcome flips to Stale — but the act of finishing isn't itself an act of thinking about the Outcome. The user has to come back and clarify what's next; that re-clarification is what stamps."
>
> **Dev:** "And declaring the *Outcome* itself done?"
> **Domain expert:** "Stamps. Saying 'this is achieved' is a structural decision about the Outcome — a clarification act. Same for trashing."
>
> **Dev:** "If a user moves an Outcome from Next to Someday/Maybe, is the Outcome 'removed from' Next and 'added to' Someday/Maybe?"
> **Domain expert:** "No — neither List has a membership column. Both are implicit Lists. The user changes the Outcome's Intent from `next` to `maybe`, and the Outcome's membership in both Lists changes as a consequence of the filter. The Lists are projections, not buckets — the model doesn't move the Outcome anywhere."
>
> **Dev:** "What about the Focus Session's task list? Is that the same kind of thing?"
> **Domain expert:** "No — that's an explicit List. It has a stored membership (which Outcomes were selected for today). Both are Lists, but the explicit/implicit split matters for how mutation works: adding to Next means changing an Outcome's Intent; adding to a Focus Session's task list means writing a membership row."

#### Flagged ambiguities

- The codebase currently conflates **Capture** and **Outcome** into a single `Todo` row (the `clarified` boolean axis distinguishes the two states). The conceptual model treats them as distinct entities with a many-to-many relationship between them.
- The codebase stores **Action** data as cursor-fields on the Outcome row (`next_action_text`, `energy_level`, `time_estimate`, `time_spent_minutes`, `last_next_action_completion_at`) rather than as rows of a separate Actions table. The proposal at `docs/proposals/blockers-and-contexts.md` framed this as "NextAction is a lightweight cursor" — but that framing was the path of least resistance to ship Blockers, not a settled design decision. The conceptual gap (Action as a first-class entity with its own lifecycle, identity, and history) is real and remains open; implementation timing is a separate question.
- The codebase has no representation of **planned** Actions today. The conceptual model treats the *plan* (an Outcome's ordered set of planned Actions) as a distinct thing the user externalises during clarification. Implementation may render this as a structured list of Action rows, as a free-text bullet list under Outcome notes, or as something an LLM parses at read time — all are valid implementations of the same concept.
- **`clarified` (boolean)** on the current Todo row is an artifact of the Capture/Outcome conflation. Once Capture is split out, every Outcome is by construction clarified, and the boolean dissolves. **`last_clarified_at`** is a distinct concept — staleness of the *current* clarification — and survives the split.
- The codebase uses "Todo" (DB table, Drift class) and "Task" (docs, foreign-key columns like `task_id`) for what the model calls an **Outcome**, and "NextAction" / `next_action_text` for what the model calls an **Action**. The proposal at `docs/proposals/blockers-and-contexts.md` uses "Task" and "NextAction" throughout; that document predates these renames.
- The proposal's four long-term states (`active / someday / done / trashed`) collapse two independent axes (Intent and Completion) into one enum. The current code's `intent` column (`next / maybe / trash`) is the Intent axis; `done_at` is the Completion axis. The proposal's wording is the conceptual error; the code happens to be closer to right.
- A trivially-actionable Capture (e.g. "call John") could in principle skip Outcome creation and land directly as an Action. The current model says no — every Capture clarifies through an Outcome, even a one-Action Outcome — to keep the path uniform. Open if a strong case emerges.
- The current code calls the **Next** List "Next Actions" throughout (provider names, screen names, UI copy). The List is conceptually a List of Outcomes — the action focus comes from each Outcome's current Action — so the plural-Actions name misleads. Renaming target: **Next** in code, providers, and copy; the role-label "Next Action" stays for the singular current Action of a row in that List.

### Engagement

#### Language

**FocusSession**:
A user session comprising three phases — **Planning**, **Execution**, and **Review** — during which the user engages with a curated subset of Outcomes. Calendar-independent: the same workflow applies whether multiple FocusSessions occur in a day or a single FocusSession spans multiple days. The UI currently surfaces FocusSession's lifecycle at a daily cadence through the planning and review Ceremonies (see Ceremony Framework context — TBD), but cadence is a UI choice, not a domain constraint. At most one FocusSession is open per user at any time.

The three phases:

- **Planning** — the user opens a FocusSession and curates its **Plan**: an explicit List of Outcomes scoped to this session. Surfaced today by the `focus_session_planning` Ceremony ("Daily Planning" at the daily cadence).
- **Execution** — the body of the session. The user engages with one Outcome on the Plan at a time via its current Action; the **Focus** (below) identifies which. TimeLogs accumulate against the focused Outcome's current Action.
- **Review** — the user closes the FocusSession, assigning a **Disposition** to every non-completed Outcome (from the Plan or off-Plan engagement). Surfaced today by the `focus_session_review` Ceremony ("Evening Shutdown" at the daily cadence).

The **Plan** is a property of the FocusSession, not a stand-alone entity — it has no existence or meaning outside the session it scopes. A user-facing UI may render the Plan with cadence-flavoured copy ("Today's Plan" at the daily cadence), but the domain concept is just "the FocusSession's Plan."

The **Focus** is the property on FocusSession identifying which Outcome on the Plan is currently being engaged with. Like Plan, it has no existence outside the session. The Focus is set when the user starts engaging with a chosen Outcome from the Plan; it may be null (no Outcome focused — e.g. a freshly-opened session, the gap between Outcomes, or a session whose Outcomes have all completed). User-facing copy may say "in progress" or "active task"; the domain name is Focus.

A sibling concept, **PeriodicSession**, will be added when the Weekly Review surface is grilled — it is a separate entity, not a parameterisation of FocusSession (per proposal §6.1, #185).
_Avoid_: Engagement Session, Work Session, Day Session, Daily Session (all imply a cadence FocusSession is deliberately decoupled from)

**Engagement**:
The act of doing the current Action of an Outcome — manifests as TimeLog accumulation against that Action. The third sibling alongside **Clarification** and **Organising**. Does not stamp `last_clarified_at` (Engagement is the *signal* that re-clarification may be due, not the act of clarifying).

Engagement is **independent of FocusSession**: the user may engage ad hoc with any Outcome from any List, at any time, with or without an open FocusSession. The FocusSession is the *recommended* discipline — its Planning and Review phases create a curated environment for engagement — but the presence (or absence) of a session does not gate the act of doing.
_Avoid_: Doing, Execution (Execution is FocusSession's middle phase, not the verb), Work

**TimeLog**:
A record of one continuous interval of engagement with a specific Action. Each TimeLog carries:

- A reference to the engaged Action (required)
- A start time (required)
- An end time (null while open / in-progress; set when the engagement ends)
- Optional attribution to the open FocusSession at start time (null for ad-hoc engagement)

Invariants:

- At most one TimeLog is open per user at any moment — Engagement is sequential.
- **There is no "pause" concept.** A TimeLog runs continuously from start to stop. The user either keeps engaging or stops (closing the TimeLog); resuming later opens a new TimeLog.
- During Pomodoro, sprint→break and break→sprint transitions do **not** close the TimeLog. Breaks are part of engagement — the clock keeps running through them.

Switching Actions closes the current TimeLog and opens a new one against the new Action.
_Avoid_: Activity, Interval, WorkLog, Session (overloaded), Pause / Resume (these vocabulary items were removed in #246 / PR #252 — see ambiguities)

**Timebox**:
A scheduled interval — a start time and a duration — attached to a Plan entry of a FocusSession, expressing *when within the session* the user intends to engage that Outcome. A property of the (FocusSession, Outcome) Plan membership, not a stand-alone entity: at most one Timebox per Plan entry, and it shares the Plan's lifecycle — it has no existence outside its session and always dies with it. Review's `rollover` Disposition carries the *commitment* (the Outcome arrives pre-selected in the next session's Planning) but never the Timebox; scheduling is redone fresh each Planning phase, against that day's calendar. A Timebox is an *intention*, not a record: actual engagement is captured by TimeLogs, and the Timebox-vs-TimeLog gap is preserved as information, like the Plan-vs-engaged gap. Scheduling is not a state axis — an Outcome with a Timebox keeps its Intent and its List memberships unchanged (the retired `state: scheduled` framing is a conceptual error).
_Avoid_: ScheduledTask, CalendarBlock, Slot, Event (Event is reserved for external-calendar entries), "scheduled" as a state

**Sprint** / **Break**:
Subdivisions of a TimeLog applying the Pomodoro discipline. A **Sprint** is a timed work block; a **Break** is the rest block between Sprints. The clock keeps running through both — Sprints and Breaks subdivide the TimeLog's rhythm without breaking its continuity. Purely a UI overlay and discipline aid — **not persisted as entities, not tracked in the model**. The only structural contact Pomodoro has with the rest of the system is the UI's pre-computed Sprint count for an Action, derived from `Action.time_estimate / Sprint duration` — and even that is presentational rather than required.
_Avoid_: PomodoroPhase, FocusBlock, WorkBlock

**Disposition**:
The user's decision in the Review phase for an Outcome that did not complete during the FocusSession. One of three values:

- `rollover` — pre-select this Outcome for the next FocusSession's Planning (user can deselect there).
- `leave` — return to its normal List membership; no special handling.
- `maybe` — set Intent to `maybe`, moving the Outcome to Someday/Maybe.

A Disposition is recorded per-(FocusSession, Outcome) pair — it is a property of the relationship between the session and the Outcome, not of either standalone. Applied to every non-completed Outcome surfaced in Review (the union of Plan members and off-Plan engaged Outcomes). Completed Outcomes need no Disposition.
_Avoid_: Resolution, Decision, Handling, Action (overloaded)

#### Relationships

- The **Plan** is a *commitment* set captured during the Planning phase; it does not auto-mutate during Execution. Off-Plan engagement is allowed and attributes to the session, but does not modify the Plan. The Plan-vs-actually-engaged gap is preserved as information — useful for retrospection, coaching, and future AI augmentation.
- **Focus** may point to any Outcome the user is engaging with, whether or not that Outcome is on the Plan.
- A **TimeLog** writes attribute to the open FocusSession (if one exists at engagement time) regardless of whether the engaged Outcome is on the Plan. If no FocusSession is open, the TimeLog is ad hoc — no session attribution.
- The **Review** phase surfaces every Outcome that was either on the Plan or engaged with during the session (the union), so neither off-Plan work nor planned-but-untouched Outcomes slip past disposition.
- A **Timebox** belongs to exactly one Plan entry (at most one per entry) and shares the Plan's lifecycle — created or edited during Planning (and adjustable during Execution), never surviving the session. Off-Plan engagement is by definition un-timeboxed. TimeLogs record what actually happened; Timeboxes record what was intended — the two are never reconciled destructively.
- **An Action may have many TimeLogs** over its lifetime — different engagement intervals on the same Action, possibly across multiple FocusSessions, possibly interspersed with engagement on other Actions within the same FocusSession. An Outcome's TimeLogs are the union of its Actions' TimeLogs.
- **The hierarchy is FocusSession → TimeLog → (Sprint+Break cycles).** A FocusSession is "from when the user sits down at the table to when they get up" and contains multiple TimeLogs (one per engagement interval). Each TimeLog is subdivided into Pomodoro Sprint+Break cycles at the user's chosen cadence as a UI rhythm; the cycles do not persist or break the TimeLog's continuity.

#### Flagged ambiguities

- "Plan" is polymorphic in Jeeves' vocabulary. The **FocusSession's Plan** (this context) is a List of *Outcomes* selected for one session. An **Outcome's plan** (GTD Core) is its List of *planned Actions* — the user's externalised "what's next" thinking for a single Outcome. Different scopes, same English word; context disambiguates. If the clash bites in code or copy, the per-Outcome notion can be rewritten as "the planned Actions of an Outcome" without losing meaning; the per-session notion is the one that needs the short name.
- **There is no "pause" in the engagement model.** An earlier implementation surfaced a pause control which was actually an unlabelled "start break" — corrected in #246 / PR #252 (commits a95c7ab, 2efab56, bfc6d66). Residual `pause` / `isPaused` / `resume` references may persist in code, copy, or older docs; treat any such reference as a candidate for removal. The two real intents the misnomer collapsed: *abandon sprint* (Stop) and *take a break* (Start break — a phase transition, not a clock suspension).
- **Off-Plan dispositions have no durable home yet.** The Review surface is defined as the Plan ∪ engaged union, and `FocusSessionDao.getReviewSurface` implements that storage contract — but the shipped Evening Shutdown UI reads Plan members only (`watchActiveSessionTasks`), and dispositions persist to `focus_session_tasks` rows, which off-Plan Outcomes do not have: a `maybe` disposition's intent edit would land, a `rollover` would be silently dropped (`getLastClosedSessionRolloverTaskIds` reads only Plan rows), and the "worked on in a session" stamp (`last_next_action_completion_at`) covers Plan members only. Off-Plan engagement became reachable in production with the task-detail `Start focus` affordance (issue #180), so the Review-side gap is now live. Reconciliation — wiring the shutdown to `getReviewSurface` and giving off-Plan dispositions durable storage without growing the Plan — is a follow-up story.

### Ceremony Framework

#### Language

**Ceremony**:
A guided activity the user performs with the app's facilitation. The app surfaces structure, prompts, and sequencing; the user provides the decisions and judgments. A Ceremony is a core domain concept — *what* the user is doing — independent of *how* the app surfaces it. May be implemented as a Wizard (the most common form), but other shapes are possible (single modal, inline form, voice flow, etc.). The current set: `focus_session_planning`, `focus_session_review`, `periodic_review`, and the in-flight inbox-clarification flow (when it splits from session planning per #184).

Each Ceremony **performance** has a lifecycle: **not-started** (no performance currently underway) → **in-progress** (the user has opened the Ceremony but not yet finished or abandoned it) → **terminated**. Termination splits two ways: **completed** (the user finished the Ceremony successfully — Triggers may treat this as the Ritual being satisfied) and **abandoned** (the user exited without finishing — Triggers treat this as if the performance hadn't happened). Multiple performances accumulate over a Ritual's lifetime; a Trigger may consult performance history (most recent completion, completion within a freshness window, etc.) as part of its own predicate. The **in-progress** state is the basis of the Nudge's in-progress hygiene rule (see ADR-0009 and the Nudge entry): no Nudge of this Ritual surfaces while one of its performances is in progress.

An abandoned performance's working state may **seed** the next performance of the same Ceremony: re-entering restores the user's place (step, per-item cursor, recorded selections) from the abandoned draft. Seeding is an in-memory implementation convenience — the seed draft is in-memory only and silently degrades to a fresh start after process death, which is accepted behaviour, not a defect — and it does not alter the lifecycle or Trigger semantics: in-progress hygiene reads only the in-progress state, and completion history records only completed performances.
_Avoid_: Ritual (narrower — see below), Wizard (an implementation form, see Implementation tier), Flow

**Ritual**:
A Ceremony that the app treats as integral to the user's practice — strongly suggested, regularly nudged for, expected to recur. The "Daily Planning Ritual" is a Ritual because the app considers it core to Jeeves' opinionated GTD discipline. An ad-hoc clarification of a one-off Capture is just a Ceremony, not a Ritual. The Ritual designation adds a *discipline overlay* on top of the underlying Ceremony — not a separate kind of activity. Today the discipline overlay takes the shape of a **Cadence** and a **Nudge**; other shapes are conceivable (streak tracking, partner accountability, etc.) but not modelled. The abstract layer is left informal until a second shape is needed.

A Ritual carries a **priority** — a linear ordering used to position its Nudge in the **Nudge queue** (see the queue entry) when more than one Ritual's Nudge is visible at the same time. Today the order is hardcoded:

```text
Weekly Review  >  Daily Planning Ritual  >  Evening Shutdown
```

Weekly Review is highest because it restores the trusted state that Daily Planning operates on (GTD orthodoxy: Daily Planning against a stale Next list violates the method). Evening Shutdown is temporally last and rarely competes with the other two; the position is chosen for completeness. Priority lives on Ritual; the Nudge references it for queue placement.
_Avoid_: Habit, Practice, Routine (none carry the "integral to the app's discipline" connotation precisely)

**Trigger**:
An autonomous predicate-with-edge-detection that fires its Nudge to visible when the predicate transitions false→true. A Nudge has one or more Triggers; Triggers are independent of each other and of Cadence period semantics — each Trigger owns its full domain logic, including any "is the Ritual stale enough to nag again?" check.

A Trigger's predicate may consult any domain state — Ceremony completion history, content-state queries, time-based windows, anything — and produces an edge each time it newly evaluates true. Each Trigger defines its own refire semantics:

- The **Cadence Trigger** is the canonical shape — fires once per anchor-to-anchor period (the predicate is "current time has crossed into a new period AND the Ritual has not been completed in this period"); refires at the next period boundary.
- **Content-state Triggers** are domain predicates over the user's data. Today's only example: the Weekly Review's "Next list is empty AND Waiting For / Someday-Maybe still holds items" Trigger, which refires whenever the predicate transitions false→true mid-period.

A Trigger's predicate may also include **world-state preconditions** — facts about the system that gate whether the Ritual makes sense at all. World-state preconditions stay inside the Trigger's predicate, not as separate Ritual-level rules; Triggers remain autonomous. Today's examples are FocusSession-lifecycle gates (only one FocusSession can be active at a time, per the Engagement context):

- The Daily Planning Ritual's Cadence Trigger predicate is "DPR period has turned AND no FocusSession is currently active AND DPR has not been completed in this period." A FocusSession is opened by DPR's completion (the Planning phase commits to opening one); attempting a second DPR while one is already open is incoherent.
- The Evening Shutdown's Cadence Trigger predicate is "ES period has turned AND a FocusSession is currently active AND ES has not been completed in this period." ES is the Review phase of the active FocusSession; without one, it has nothing to operate on.

A Trigger may borrow a default snooze duration from Cadence; the reference is explicit in the Trigger's implementation rather than a model-wide default.
_Avoid_: Event (Triggers are predicates with edge semantics, not point-in-time events), Condition (too generic), Predicate (a Trigger *contains* a predicate but adds edge-detection and Nudge-firing)

**Nudge**:
The app's mechanism for suggesting a Ritual to the user — a contextual reminder that the disciplined Ceremony is due. Belongs only to Rituals (not all Ceremonies); ad-hoc Ceremonies are user-initiated and need no Nudge.

A Nudge is composed of:

- One or more **Triggers** — autonomous predicates that, on transitioning false→true, fire the Nudge to visible.
- Persisted user-interaction state — `dismissed_at` (timestamp of the most recent dismiss action) and `snoozed_until` (timestamp the snooze expires).

A Nudge's visibility is a *computed predicate*, not stored:

```text
visible =
    (some Trigger is currently firing)
  ∧ (no Ceremony performance of this Ritual is currently in progress)   ← in-progress hygiene, see ADR-0009
  ∧ (snoozed_until is null or now > snoozed_until)
  ∧ (dismissed_at is earlier than the most recent Trigger firing edge)
```

**Dismiss** is scoped to the *current firing*, not to a time window. A dismiss hides the Nudge until any Trigger next fires (per that Trigger's own rules); it is not period-scoped, so a Trigger that fires immediately after a dismiss re-surfaces the Nudge.

**Snooze** is time-bound. Snoozes may be **user-explicit** (chosen duration) or **system-implicit** (a default duration applied by a surface — e.g., a Notification swipe-away which the system interprets as a low-signal "not now"). The default duration for a system-implicit snooze may be borrowed from Cadence, but that is an explicit per-Nudge reference in the snoozing surface, not a model-wide default.

**Completion** of a Ritual is a Ceremony-level fact (see Ceremony's lifecycle), not a Nudge state. Each Trigger decides for itself whether and how to incorporate completion into its predicate (the Cadence Trigger naturally respects "not completed in current period"; content-state Triggers define their own freshness rules).

**In-progress hygiene** is the one centralised non-content rule the Nudge model carries: while any Ceremony performance of this Ritual is in progress, the Nudge is hidden regardless of Trigger state. Triggers remain autonomous about their content; the hygiene rule is content-independent and applies uniformly. See ADR-0009.

A Ritual has at most one Nudge. The Nudge's *surfaces* — how the user actually sees it — are Implementation: see **Banner** and **Notification** in the Implementation tier. Surfaces are pure projections: they read Nudge state to render and write Nudge state on user action. Each surface's user-action → Nudge-transition mapping is calibrated to its **signal fidelity** (Banner ✕ is an explicit in-app gesture and maps to dismiss; a Notification swipe is low-signal — possibly mass-dismiss fatigue — and maps to a system-implicit snooze).

Visible Nudges across all Rituals form the **Nudge queue**, ordered by each Nudge's Ritual priority (see Ritual). Surfaces consume the queue rather than reading individual Nudges — Banner and Notification take the queue head; future surfaces may consume more. A Nudge's own visibility predicate stays independent of other Rituals' state; cross-Ritual ordering is the queue's concern.
_Avoid_: Reminder (a separate concept — see ambiguities), Prompt, Suggestion (overloaded with AI surfaces)

**Cadence**:
The recurring schedule that determines when a Ritual is due. A Cadence has two properties:

- **shape** — the calendar pattern (daily, weekly, every-N-days). Drives cadence-flavoured copy ("Today's Plan" at the daily cadence, "This Week's Review" at the weekly cadence). Hardcoded per Ritual today.
- **anchor** — the specific moment within the shape on which period boundaries land (e.g., 8 AM for a daily cadence, Sunday-09:00 for a weekly cadence). Some Rituals carry hardcoded anchors; others read them from synced preferences. Whether a given anchor is hardcoded or user-tunable is an implementation detail *inside* the Cadence; the conceptual model treats the anchor as a Cadence property either way.

The period runs anchor-to-anchor (see ADR-0008 for the trade-off and the future possibility of Cadence-as-strategy). The Cadence powers exactly one Trigger of the Ritual's Nudge — the Cadence Trigger — which fires when "current time has crossed into a new period AND the Ritual has not been completed in this period." Other Triggers (content-state, event-based) are independent of Cadence and define their own firing semantics.

Belongs only to Rituals; ad-hoc Ceremonies have no Cadence (they happen when the user chooses). Current Rituals carry hardcoded shapes: Daily Planning (daily), Evening Shutdown (daily), Weekly Review (every 7 days). Anchors are user-configurable for some surfaces today (Daily Planning's notification time, for instance) and hardcoded for others.
_Avoid_: Schedule (overloaded — implies fixed times of day), Frequency (less precise), Period (too generic), Rhythm (informal)

**Nudge queue**:
The priority-ordered list of currently-visible Nudges across all Rituals. Each Nudge enters the queue when its own visibility predicate (see Nudge) is true; the queue position is determined by the owning Ritual's priority. The queue exists *above* individual Nudges — each Nudge's own predicate stays independent of other Rituals' state — because surfaces, especially single-occupancy ones, need an unambiguous answer to "of the visible Nudges, which one do I show right now?"

Surfaces consume the queue per their own rules:

- **Banner** (Implementation tier) is a single-occupancy in-app slot — it renders the queue head when the queue is non-empty.
- **Notification** (Implementation tier) takes the queue head — at most one Ritual's Notification fires at a time. (The OS can stack multiple notifications in principle, but doing so would send the user contradictory guidance — e.g., "plan your day" while "your trusted list is stale; review first.")
- A future **Agenda** or **WorkPlan** surface may consume the full queue in priority order ("First Weekly Review, then Daily Planning…"), giving the user a forward look at what is on their plate.

When the head's Nudge becomes invisible (completion, dismissal, snooze, in-progress hygiene, Trigger predicate flipping false), the next bubbles up and the consuming surfaces re-render against the new head. The queue is recomputed reactively from the participating Nudges' visibility predicates and the participating Rituals' priorities.
_Avoid_: stack, list (too generic), priority list (acceptable but Nudge queue is the canonical term)

#### Relationships

- A **Ritual** is a **Ceremony** with a *discipline overlay*. Today the overlay is composed of a **Cadence** and a **Nudge**; removing both demotes a Ritual to a plain Ceremony, adding them promotes a Ceremony to a Ritual. The abstract "discipline overlay" layer is left informal until a second shape is needed.
- A **Nudge** is composed of one or more **Triggers** plus persisted dismiss/snooze state. Visibility is computed from Trigger firings, snooze, dismiss, and the Ceremony's in-progress state (see the Nudge entry for the predicate).
- A **Trigger** is autonomous — independent of other Triggers and of Cadence period semantics. The **Cadence Trigger** is the canonical shape; content-state Triggers (per Ritual) are others. Each Trigger owns its full domain logic, including completion-freshness rules.
- **Completion** of a Ceremony performance is a Ceremony fact, not a Nudge state. Triggers may consult Ceremony lifecycle and performance history per their own predicates; the Nudge does not centralise completion.
- The **in-progress hygiene rule** is centralised at the Nudge level: while any Ceremony performance of this Ritual is in progress, no Nudge of this Ritual is visible regardless of Trigger state (ADR-0009). This is the one non-content rule the Nudge model carries.
- A **Nudge** has zero or more *surfaces* (currently **Banner** and **Notification**) that deliver it to the user. Surfaces are pure projections — they read Nudge state to render and write Nudge state on user action. Each surface's user-action → Nudge-transition mapping is calibrated to its signal fidelity (e.g., Banner ✕ → dismiss because it is an explicit in-app gesture; Notification swipe → system-implicit snooze because it is low-signal). Adding or removing surfaces does not change what a Nudge *is*.
- The **Nudge queue** orders currently-visible Nudges across all Rituals by Ritual priority (linear, hardcoded today: WR > DPR > ES). Surfaces consume the queue rather than reading individual Nudges directly — Banner and Notification take the queue head, future surfaces may consume more. The queue is a layer *above* individual Nudge visibility; each Nudge's own predicate stays independent of other Rituals' state.
- A **Trigger** may consult state from other contexts as part of its predicate. Today's FocusSession-lifecycle gates live in the relevant Cadence Trigger predicates (DPR's "no FS active," ES's "FS active"), not as separate Ritual-level rules. The Engagement context's "only one active FocusSession" invariant is the ground truth; Triggers read it.
- A **Ceremony** may be implemented as a **Wizard** (current default for all three Rituals) or any other UI form. The implementation form is independent of the Ceremony concept.
- **Disposition** (defined in Engagement) is the per-Outcome decision used inside FocusSession's Review-type Ceremonies (Evening Shutdown). Other Ceremonies — notably the forthcoming PeriodicSession review — may introduce their own decision vocabularies.

#### Flagged ambiguities

- **Nudge** (this context) and **Reminder** (forthcoming, GTD Core) are different concepts. A Nudge targets a *Ritual* — the app suggesting "it's time for your weekly review." A Reminder targets an *individual Action* — "remind me to call John at 5pm." Different scopes, different triggers, different lifecycles. Do not collapse them into a single primitive even though both involve OS notifications under the hood.

### Sync

Sync is responsible for bidirectional offline-first replication between the Flutter app's local SQLite store and the PostgreSQL backend. Most of its vocabulary is technical and lives in the Implementation tier; the user does not think in sync vocabulary — they expect data to follow them across devices and the app to work without connectivity, without naming the mechanisms that achieve either. What belongs in this section is the Relationships subsection — the architectural discipline that keeps Sync from leaking upward into the contexts above it.

#### Relationships

- **Sync types do not appear in GTD Core / Engagement / Ceremony Framework function signatures.** The dependency direction is strictly one-way: those three contexts speak Drift/in-memory entities; Sync mechanically replicates those entities to PostgreSQL without adding semantics. Any change that would add a Sync-tier type (Bucket, Sync Token, BackendConnector reference) to a method signature in another context is the warning sign.
- **Sync is additive — the app's offline behaviour does not depend on a working Sync layer.** If the BackendConnector fails to reach the backend, local writes queue and the user continues to work; replication resumes when connectivity returns. Conversely, if Sync is configured off entirely, the app remains fully functional as a single-device GTD store.
- **Each context owns what is replicated.** GTD Core decides Outcomes, Actions, Tags, etc. are replicated; Engagement decides FocusSessions and TimeLogs are; Ceremony Framework has nothing structural to replicate today. Sync mechanically follows those choices but does not influence them.
- **Local-only state is not replicated by design.** Sprint timer state in SharedPreferences, ephemeral UI focus, and per-device preferences (when added) stay local. Each context's Implementation tier specifies what is local-only versus replicated.
- **Conflict resolution defaults to Last-Write-Wins (LWW).** Acceptable for the current single-user-many-devices model; collaboration features (when they land) may require operation-based or CRDT-style resolution on the shapes they touch. For `user_preferences`, the default is refined by a per-key **Conflict Strategy** registry (see Implementation tier): a few keys need non-LWW arbitration, and the default must be non-destructive for future keys.

## Implementation

**Tag** *(backs the GTD Core concepts Person, Area, Label, and legacy Context)*:
The shared storage row backing several conceptual entities, discriminated by a `Tag.type` field. Outcome ↔ Tag links are stored in a `TodoTags` join table; the join carries no role information of its own (its semantics depend entirely on the linked Tag's `type`). The user does not think in terms of Tags — they think in terms of the domain entities Tag backs. Physical-world equivalent: a folder, sticky note, or label-maker — a categorisation mechanism, not a domain concept. Each conceptual entity Tag currently backs has its own Conceptual-tier glossary entry; this entry exists so the code's `tags` table has a name in this glossary without implying that "Tag" is part of the user's mental model.
_Avoid_: (none — Tag is the canonical name for the storage)

**Banner** *(an in-app surface for a Nudge)*:
A persistent, single-occupancy visual element rendered at the top of shell-hosted screens. The Banner consumes the head of the **Nudge queue** (Conceptual tier) — when the queue is non-empty, the Banner renders the highest-priority visible Nudge; when the queue is empty, the Banner is absent. The Banner ✕ is a high-signal in-app gesture and maps to a Nudge **dismiss** (suppress the current firing — re-surfaces on the next Trigger firing edge of the same Nudge). Tapping the body opens the underlying Ceremony. User-facing dismissal copy is cadence-flavoured ("Not today" at daily cadence, "Not this week" at weekly), but the underlying state transition is the same. Today each Ritual has its own bespoke Banner implementation — a target for consolidation under a single Nudge-queue-driven Banner abstraction.
_Avoid_: Toast (transient), Snackbar (transient), Alert (overloaded)

**Notification** *(an OS-level surface for a Nudge)*:
A platform-delivered alert (Android / iOS / web push) that surfaces a Nudge even when the app is not in the foreground. Like the Banner, the Notification surface consumes the **Nudge queue** head — at most one Ritual's Notification fires at a time. The OS can stack multiple notifications in principle, but doing so would send the user contradictory guidance, so the surface intentionally restricts itself to the head. The user-facing actions and their Nudge mappings:

- **open** — opens the underlying Ceremony.
- **snooze** (explicit action button) — user-explicit Nudge **snooze** with a chosen duration.
- **skip** (explicit action button) — high-signal **dismiss** (current firing). User-facing copy is cadence-flavoured ("Skip today" at daily cadence, "Skip this week" at weekly).
- **implicit swipe-away** — low-signal; mass-dismiss fatigue makes this an unreliable indicator of intent, so the surface maps it to a **system-implicit snooze** with a default duration (which the implementation may borrow from the Ritual's Cadence; see the Nudge entry).

Today each Ritual schedules its own Notification — same consolidation target as Banner.
_Avoid_: Push, Alert, Reminder (Reminder is a separate concept — see ambiguities)

**PowerSync** *(the current Sync engine)*:
The replication engine used by Jeeves — a self-hosted `journeyapps/powersync-service` instance providing bidirectional sync between the Flutter SQLite store and the PostgreSQL backend. PowerSync uses Postgres for its internal bucket storage; no separate sync database is required. The engine is replaceable in principle — Sync's discipline rule (Sync types don't leak into other contexts) is what protects the rest of the app from a hypothetical engine swap.
_Avoid_: (none — PowerSync is the canonical name for the current engine)

**Sync Shape** *(one of the seven replicated data subsets)*:
The schema definition of a subset of model data that replicates per user — specifies which rows belong in the user's replication stream and how they are filtered. The current seven Sync Shapes: `todos`, `tags`, `todo_tags`, `time_logs`, `focus_sessions`, `focus_session_tasks`, `user_preferences`. All seven are filtered by `user_id` directly; the junction tables (`todo_tags`, `focus_session_tasks`) carry a denormalized `user_id` for this purpose, since PowerSync forbids JOINs in bucket data queries.
_Avoid_: Sync rule (PowerSync's internal term), Replication shape, Sync schema

**Bucket** *(the runtime replication unit)*:
A single user's instance of a Sync Shape — the actual replication stream materialised by PowerSync. One Bucket exists per `(user, Sync Shape)` pair. The user never sees a Bucket; the term exists for code and operational debugging.
_Avoid_: Sync stream (vaguer), Channel (overloaded), Shard

**BackendConnector** *(the local-to-backend upload path)*:
The interface (currently `JevesBackendConnector` in code) that PowerSync uses to upload local writes to the Jeeves backend's REST API. Local writes are queued by PowerSync and replayed through this connector when connectivity is available. The Sync engine reads from the backend's PostgreSQL directly; only writes flow through the connector.
_Avoid_: Sync connector (acceptable but BackendConnector is the canonical class name), Upload pipe

**Dead Letter** *(a recorded non-retryable upload failure)*:
A diagnostic record of a queued local write the BackendConnector could not upload for a non-retryable reason (per-status policy in `docs/ARCHITECTURE.md § Upload-error policy`), persisted in the local-only `sync_dead_letters` table with the operation, table, payload, status, and response body. Developer telemetry, not a user-facing retry queue: the failure surfaces through the sync indicator, and resolution means fixing the root cause so the table trends toward empty.
_Avoid_: Failed upload queue (implies replay), Sync error log (vaguer)

**Sync Token**:
The short-lived JWT issued by the backend's `GET /powersync/credentials` endpoint and consumed by PowerSync for authentication. The backend signs it with `SECRET_KEY`; PowerSync validates with the same key. Distinct from the user's auth tokens (access / refresh JWTs from the auth provider), though the v1 implementation shares the signing key.
_Avoid_: PowerSync token (acceptable colloquially but Sync Token is the canonical name), Sync credential, JWT (too generic)

**Last-Write-Wins (LWW)** *(the default conflict resolution policy)*:
The default conflict resolution rule for replicated data: when concurrent edits from multiple devices target the same row, the edit with the latest `updated_at` timestamp wins. Acceptable for the current single-user-many-devices model; future collaboration features may require operation-based or CRDT-style resolution on the shapes they touch. For most tables it is applied implicitly by PowerSync via the `updated_at` column. For `user_preferences` it is the default entry of the **Conflict Strategy** registry, and a few keys deviate from it.
_Avoid_: Last-write-wins (capitalisation drift), Latest wins, Newest wins

**Conflict Strategy** *(per-key `user_preferences` reconciliation rule)*:
The rule that decides which value a `user_preferences` row holds after a local and a server copy conflict. Defined per key in a code registry (`services/user_preferences_conflict.dart`) so the policy is an auditable contract rather than an implicit engine behaviour, and so future keys register a strategy rather than editing prose. Three strategies exist: **LWW** (default, non-destructive; scalar keys), **max-timestamp-value** (snooze "until" floors — between two live values the later one wins so a floor never regresses, while a clear/un-snooze is arbitrated against a live value by last-write-wins on `updated_at`), and **set-merge** (union of list values so concurrent additions survive; provisioned, no key uses it yet). The default must be non-destructive for any future key. The full matrix lives in `docs/SYNC.md`; see also ADR-0011.
_Avoid_: Merge policy (vaguer), Resolution mode

**Tombstone** *(the deletion shape for synced key-value rows)*:
Deletion in `user_preferences` is a present row with `value = NULL`, never a physical row removal. This invariant is what makes reconciliation unambiguous: an **absent** server row can only mean "never synced" (keep local), while a real cross-device **delete** arrives as a tombstone row (a value, not a gap). So "server-absent → keep local" can never swallow a legitimate delete.
_Avoid_: Soft delete (acceptable colloquially; Tombstone is the canonical term here), Deleted flag

**Wizard** *(one possible implementation form for a Ceremony)*:
A UI/UX pattern for guiding a user through a structured multi-step input flow. Carries the affordances expected of the pattern: next / back / skip controls, a progress indicator, a status line, and optionally intra-step progress for compound steps. A Wizard is composed of **Steps** — bounded sub-activities sequenced linearly, each with its own subject and UI surface. When a step's snapshot is empty, the step body shows an empty-state view and the user clicks Next to advance; steps do not auto-skip. While the Wizard's page transition animates, the footer slot absorbs taps — the footer swaps to the incoming step's widget the moment the step index changes, so without absorption a double-tap would advance two steps. System back mirrors the active step's footer Back affordance; when Back is unavailable (first step, first item, or a completion screen) it exits the Ceremony to the execution home screen, abandoning the performance (see the Ceremony lifecycle; implemented by `CeremonyPopScope`, shipped alongside the Wizard). The current code implements every Ceremony (Daily Planning, Evening Shutdown, Weekly Review) as a Wizard through a single Ceremony-parametrised `Wizard` widget (`app/lib/widgets/ceremony/wizard.dart`) composing a list of `WizardStep` values. Ceremony screens supply each step's body and its footer widget; the Wizard owns only the header (ceremony label, step title, segmented progress, subtitle) and the non-swipeable [PageView] hosting the step bodies. Footers are owned by the step, drawn from a small set of shared widgets: `WizardFooter` (Back + primary Next step), `ListItemFooter` (Back + Skip↔Next-step swap for list-driven steps, contract per `docs/DESIGN.md:119–135`), and `BackOnlyFooter` (Back alone — used where dispositions inside the body drive advancement). One shared step-body primitive ships alongside the Wizard in `app/lib/widgets/ceremony/`: `ClarifyStep` (the Inbox-clarification body shared verbatim by Daily Planning and Weekly Review, wrapping `ClarifyCard` with inline loading/empty/item/completion branching and no hard-coded Riverpod dependency). Other list-driven steps inline the same loading/empty/item/completion branching directly in their own build methods. Terminal/completion screens are *not* Steps — they are post-ceremony confirmations and are rendered outside the Wizard by the ceremony screen widget once the user has walked the last real step. The Wizard form — and the Step concept along with it — is part of the *implementation*, not part of the Ceremony being implemented; a non-Wizard surfacing of a Ceremony (a single modal, an inline form, a voice flow) would not have Steps.
_Avoid_: Stepper, Carousel, MultiStep, Flow (Flow is used colloquially but is broader)
