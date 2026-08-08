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

## Conceptual

### GTD Core

#### Language

**Capture**:
A raw, unprocessed fragment the user has put into the system because it has their attention. Pending clarification; not yet an Outcome or Action. A Capture's clarification is its terminal act, recorded once as `clarified_at` — stamped when the user completes the clarify act for that Capture, whether it produced new Outcomes, merged into existing ones, or was **discarded** (a zero-Outcome clarification is a legitimate verdict, not a special case — see **Discard**). An unstamped Capture sits in the Inbox; a stamped one persists as provenance for the Outcomes it clarified into — Captures are never deleted and merge never consumes them.
**Clarification never rewrites a Capture** (ADR-0023). The clarify surface seeds its fields from the fragment and feeds the Outcome draft; the Capture keeps exactly what was captured, so what the system holds as "what I captured" stays the raw record rather than the interpretation of it. The visible consequence: correct a typo mid-clarify and Skip, and the Inbox still shows the typo while the correction rides the draft onto the Outcome when you route.

A Capture may carry **tag hints** from capture time (stored in the `capture_tags` join). Tag hints are the single exception to the rule above — they *are* written to the Capture, at capture time and during clarification. A tag hint is *not* Organising and never stamps anything: it is a suggestion the user recorded alongside the raw fragment, not a rewrite of it, surfaced during clarification as removable chips on the Outcome draft (when carving a new Outcome) and as prefill (when merging into an existing one). Organising — sorting an Outcome into structure — happens on the Outcome, not the Capture.
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
- `superseded` — replaced before completion. Carries **no** linkage metadata: no `superseded_by_id` and no dedicated `superseded_at` — its termination time is read from `updated_at`. Editing the current Action's text is an in-place edit (a refinement of the same Action), not a supersession; supersession happens only through explicit affordances (Abandon, or re-clarifying to a new or promoted Action without completing the old one).

Terminated Actions (`done` or `superseded`) stay attached to their Outcome — the time-ordered chain of terminated Action rows is the Outcome's history, and it is user-visible: the Outcome detail view renders it newest-first, read-only, under the Plan.

The history chain is honest about *what* terminated, not about *who* terminated it. A row retired by the startup reconciliation sweep (a phantom current Action repaired away) is stored as `superseded` and therefore reads as "Abandoned", indistinguishable from one the user abandoned deliberately. That is accepted: adding a marker column would amend the no-linkage-metadata rule above to disambiguate a case that only arises from repair.

**The Action rows are the only grain.** The `actions` table is the only thing the app reads or writes to answer "what is this Outcome's next move?". No Outcome column holds a next-action phrase, and no invariant ties one to the Action rows. An Outcome reduced in from a client predating the Actions table renders Actionless until re-clarified. An accidental multi-`current` set is repaired by the writers as it is encountered, never by a startup sweep.

Energy level and time estimate are Action-grain for the same reason: they describe the *action of doing*, so a replacement Action never inherits the estimate of the one it replaced. The Outcome columns remain the draft store while an Outcome is Actionless, and reads fall back to them per field. A *planned* Action carries its own effort from the moment it is written down, and through promotion — the user judging "that will be a big one" about a step not yet started is exactly the externalised thinking the plan is for.
_Avoid_: Task (when referring to the action), Step, TodoStep, Subtask, Cursor, NextAction (provisional code name — see ambiguities)

**Intent**:
The user's *willingness* to pursue an Outcome. One of `next` (yes, soon), `maybe` (yes, eventually), or `trash` (no, never). Intent is a stance, not a fact about completion.
_Avoid_: State, Status, Disposition (in this context)

**Completion**:
The fact that an Outcome has been achieved, recorded as a timestamp. Orthogonal to Intent — a user can change Intent on an unachieved Outcome without affecting Completion, and Completion happens to an Outcome regardless of Intent.
_Avoid_: Done state, Done intent

**Person**:
A person the user knows, interacts with, or depends on. Identified by a user-chosen name. A first-class concept independent of any particular Blocker or Outcome — the same Person can be referenced from many Outcomes' PersonBlockers, and from Action text ("call Trixy") regardless of blocking state.
_Avoid_: Contact, User (User is reserved for an authenticating identity — see Implementation tier), Collaborator

**Area** *(of Focus)*:
A domain of recurring responsibility — Allen's GTD horizon-2 concept. Examples: "Health", "Finance", "Family". A permanent or long-lived categorisation, and **exclusive**: an Outcome belongs to at most one Area, which is what makes an Area-by-Area pass non-overlapping — the Areas plus the Area-less remainder cover everything exactly once. Cross-cutting grouping is **Label**'s job; gating on where you physically are is **Context**'s. Allen specifies no project↔area membership at all, so the cardinality is a Jeeves choice, not GTD canon (ADR-0025).
_Avoid_: Category, Topic, Folder, Project (Project is structural; Area is responsibility-domain)

**Label**:
A user-defined granular grouping, and the system's only cross-cutting one: an Outcome carries any number of Labels, and a Label may span Areas ("urgent-this-week" across Health and Finance). Jeeves-specific extension, not GTD canon. Free-form; the user creates and retires Labels as needed. Where **Area** answers *where does this live*, Label answers *what else is this about* — which is why Area is exclusive and Label is not (ADR-0025).
_Avoid_: Tag (Tag is the storage shape, not the concept), Bucket, Area (Area is the exclusive home; Label is the cross-cutting one)

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
A named collection of items. A List may be **explicit** — its membership is stored (the planned Actions of an Outcome, the task membership of a FocusSession) — or **implicit** — its membership is a query over the system's entities (the GTD lists below, the Outcomes in an Area). The split affects storage and ordering, not the conceptual role. List is first-class across every tier: the model has explicit Lists as relations, the UI renders every multi-item view as one, and the user *thinks* in Lists. Before inventing a new "collection of X", ask which kind of List it is.
_Avoid_: Collection, View, Bucket, Queue (Queue implies FIFO, which Lists do not require)

**Inbox**:
The implicit List of Captures pending clarification (`clarified_at` is null). The user's trusted bucket for unprocessed stuff.
_Avoid_: Capture queue, Capture List

**Next**:
The implicit List of Outcomes the user is willing to handle next. Defined by:

```text
Intent = next ∧ clarified ∧ Completion is null ∧ (has current Action ∨ no PersonBlocker)
```

The user engages with the row's *current Action* — but the List contains Outcomes, not Actions. The single excluded quadrant is **actionless AND PersonBlocked**: an Outcome with no current Action that is waiting on a Person is a pure wait and surfaces only on Waiting For, whose cadence is the weekly pass. An Outcome *with* a current Action belongs on Next regardless of any PersonBlocker — "call Trixy for a follow up" is engageable while the Outcome waits on Trixy, so it appears on Next *and* under Waiting For.
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
The implicit List of Outcomes the user has discarded. Defined by: `Intent = trash` (regardless of Completion). Distinct from **Discard**, which is a verdict on a *Capture* and puts nothing on this List.
_Avoid_: Deleted, Removed (the row persists; Intent expresses the user's stance)

**Discard**:
The zero-Outcome clarification of a **Capture** — the verdict "this was never worth doing." The clarify act completes, so `clarified_at` is stamped and the Capture leaves the Inbox, but no Outcome is created (`ClarificationService.discardCapture`). The Capture itself persists as the record of what was discarded.

Discard is **not** the same verdict as **Done**, and the two must never share an affordance: Done says the Capture clarified into an Outcome that is *already achieved*, and records a Completion. Discard says there was nothing to record at all. Nor is Discard the same as **Trash**: Trash is a List of Outcomes (`Intent = trash`), and since a discarded Capture never becomes an Outcome it can never appear there.

UI label mapping — the `trash` action in `ProcessToHandlers` resolves its copy from the subject: **"Discard Capture"** on a Capture (this term), **"Trash"** on an Outcome (the List above). One code identifier, two canonical names, because the two subjects genuinely mean different things.
_Avoid_: Delete, Dismiss, Done (Done is a different verdict entirely), Trash (Trash is the Outcome-side List)

#### Relationships

- A **Capture** is many-to-many with **Outcome**: one Capture may clarify to zero, one, or several Outcomes; one Outcome may trace back to several Captures (duplicate or complementary fragments merged during clarification).
- The clarify UX runs in one of two user-selectable modes — a preference over the same many-to-many model, never a storage change. In **1-1 mode** each Capture clarifies to *at most* one Outcome — routing to an Intent creates exactly one and `clarified_at` stamps automatically at that first Outcome link, while a discard is the legitimate zero-Outcome verdict that stamps without creating anything; in **n-m mode** (split/merge) the user explicitly completes each Capture, and only that completion stamps `clarified_at` — a Capture stays in the Inbox while Outcomes are incrementally carved out of it, or merged into. Carving and merging are the same gesture on the same field: one names an Outcome that does not exist yet, the other picks one that does. Retracting a claim follows provenance — undoing a carve removes the Outcome it created, while unmerging only detaches, because merge never owned the Outcome in the first place.
- **Clarifying a Capture routes to one of three destinations** — Next Action, Waiting For, Someday — in both modes. **Done** and **Trash** are not clarify-time destinations for an Outcome: Done is a Completion, an event recorded when the work is finished, and an Outcome captured already-complete is a contradiction; Trash is an Intent the user sets on an Outcome they have decided against. Both remain available on the Outcome's own surface. At Capture scope the two terminal verdicts are **Done with this Capture** (stamp `clarified_at`, keep every Outcome) and **Discard Capture** (the zero-Outcome verdict: stamp, create nothing).
- An **Outcome** has at most one *current* **Action** at any time, may have any number of *planned* Actions (the user's externalised "what's next" thinking), and has 0..N *terminated* Actions (done or superseded) over its lifetime.
- An **Outcome** that ends up needing multiple Actions is colloquially a *project* — no separate type is required.
- An **Outcome** carries an **Intent** (the user's willingness) and may carry a **Completion** timestamp (the fact of achievement); the two axes are independent.
- An **Outcome** may have any number of **Blockers** that *coexist* with its current **Action**. The classic case: a PersonBlocker "waiting on Trixy" lives on the Outcome while the current Action reads "follow up with Trixy." Acting on the current Action is what *might* resolve the Blocker; the two are not in opposition.
- An **Action** belongs to exactly one **Outcome**. Captures reach Actions only indirectly, through the Outcomes they clarify to.
- An **Outcome** belongs to at most one **Area** (1:N — Area is the exclusive home) and is labelled with zero or more **Labels** (M:N — Label is the cross-cutting annotation).
- A **PersonBlocker** references exactly one **Person**; one Outcome may have multiple PersonBlockers (waiting on multiple Persons), and one Person may be the subject of PersonBlockers on multiple Outcomes.
- A **Person** may also appear in Action text or Outcome notes without being a Blocker — referencing a Person does not imply blocking on them.
- An **Action** may have zero or more **Contexts** (M:N) — deferred but conceptually committed; the relationship is owned by Action, not Outcome.
- **Only the *current* Action is engageable.** Planned Actions cannot have TimeLogs, do not surface in **Next** / Focus Mode / Today's Plan. They are visible only in the context of their Outcome (where the Outcome's plan — an explicit List of planned Actions — is shown).
- **Promotion from `planned` to `current` is an explicit clarifying act, never automatic.** When the current Action terminates, the Outcome enters the "no current Action" state until the user re-clarifies and either promotes a planned Action, edits one, or creates a new one.
- **The plan carries no explicit dependencies.** Ordering among planned Actions is the user's intuition about sequence, not a DAG. The user revises ordering during clarification.
- **TimeLog** records are attributed to an Action (not an Outcome) — you log time against the specific *action being performed*. An Outcome's total time invested is summed from the TimeLogs of its current and past Actions.
- **Clarification stamps `last_clarified_at` per micro-act.** The principle: a write stamps iff it constitutes thinking-about-the-Outcome. Stamping writes include Outcome creation; title/notes/Intent/due-date edits; any Action mutation (create, edit, supersede, promote, demote, reorder, remove); Blocker add/remove (including PersonBlocker, however stored); explicit "still relevant" confirmation; Outcome completion or trashing. Non-stamping writes include current Action completion (engagement signal, not clarification), TimeLog writes, and Area / Label changes (organising).
- **The three Freshness predicates compose freely.** An Outcome may be {Stale + has-current-Action}, {Actionless but with planned Actions}, {Planless and Stale}, etc. Different review surfaces emphasise different combinations — Daily Planning's re-clarify queue surfaces *Stale ∨ Actionless*; a future "abandoned Outcomes" surface might emphasise *Planless ∧ ¬Stale-but-old* (never thought about much, never planned). The predicates are the contract; the surfaces are downstream.
- **GTD List membership is defined by filter, not by an "ownership" column** — the Lists are implicit projections, so an Outcome's membership in each is decided independently by that List's predicate. Most pairs are disjoint by construction: `Intent` (`next` / `maybe` / `trash`) partitions Next, Someday/Maybe, and Trash; `Completion` separates Done from the active set; Inbox is over Captures so does not overlap with any Outcome-bearing list. The single deliberate overlap is **Next ∩ Waiting For**, and it is conditional on having a current Action: an *engageable* PersonBlocked Outcome (one with a `current` Action) appears on both — Next because the Action is doable, Waiting For because the dependency is real. An *actionless* PersonBlocked Outcome appears on Waiting For only; the Next List filter excludes it (see Next's definition). The Weekly Review wizard's Next-step snapshot applies a stricter per-step person-tag exclusion to keep its wizard steps disjoint; that is a wizard concern, not the everyday Next List rule.

#### Flagged ambiguities

- The **title-as-action fallback** is stated for **Next** and **Waiting For**; the implementation covers Waiting For only on the clarify surfaces. The shared `ProcessToHandlers` Waiting For button, which the review steps use against an *existing* Outcome, routes intent-only. The model is right and the implementation lags.
- **`clarified` (boolean)** on the Todo row is a leftover of the Capture/Outcome conflation. Inbox membership no longer derives from it, but the GTD list watchers still read it as a real-Outcome guard, so retiring it means reworking those predicates first — not a drop-in migration. **`last_clarified_at`** is a distinct concept (staleness of the *current* clarification) and survives the split.
- **Draft attributes have no home on a Capture.** A Capture carries title and notes only. Due date, energy and time estimate live as in-memory draft (`ClarifyRetention`, keyed by Capture id) and land at clarification — surviving Skip and Back but not process death. Tag *hints* are the exception: they alone persist on the Capture and seed the new Outcome's tags. Energy and time are Action-grain but still resolve from Outcome columns as fallback.
- **The codebase says "Todo" (table, Drift class) and "Task" (docs, `task_id`) for what the model calls an Outcome.** The rename is unstarted. `docs/proposals/blockers-and-contexts.md` uses "Task" and "NextAction" throughout and predates the Action rename.
- The proposal's four long-term states (`active / someday / done / trashed`) collapse two independent axes into one enum. The code's `intent` column is the Intent axis and `done_at` the Completion axis; the proposal's wording is the conceptual error.
- A trivially-actionable Capture ("call John") could in principle skip Outcome creation and land directly as an Action. The model says no — every Capture clarifies through an Outcome.
- **Area exclusivity is enforced at the cutover, not yet in storage.** Areas are `Tag(type='area')` linked through `todo_tags`, which carries no `type`, so "at most one Area" is not expressible as a unique index — it needs a dedicated Outcome→Area link or a check reaching into `tags`. Two pieces remain: storage-level enforcement, and the user's own resolution pass over the conversions the initial upload reports.
- **The code calls the Next List "Next Actions"** throughout. The List is of Outcomes — the action focus comes from each Outcome's current Action — so the plural misleads; the role-label "Next Action" stays for the singular current Action of a row. The List also carries two user-facing names: the drawer says "Next Actions", Daily Planning says "Up Next". That divergence is deliberate (the step's pool is filtered, so one name would show two counts) but neither is the model's.

### Engagement

#### Language

**FocusSession**:
A user session comprising three phases — **Planning**, **Execution**, and **Review** — during which the user engages with a curated subset of Outcomes. Calendar-independent: the same workflow applies whether multiple FocusSessions occur in a day or a single FocusSession spans multiple days. The UI currently surfaces FocusSession's lifecycle at a daily cadence through the planning and review Ceremonies (see Ceremony Framework context — TBD), but cadence is a UI choice, not a domain constraint. At most one FocusSession is open per user at any time.

A FocusSession changes lifecycle state **only by explicit user action** — it opens when the user completes Planning and closes when the user completes Review, never on its own. Cadence anchors are **reminder anchors only**: they decide when a Nudge fires, never when a session opens or closes, so an open session persists across idle time and process death until the user reviews it. At most one is open at a time, and because two Devices can each open one offline the invariant has to be *repairable* rather than merely declared (ADR-0020).

Because sessions never auto-close, **day attribution is anchor-based, not calendar midnight**: a session belongs to the planning period opened by the most recent **Evening Shutdown anchor** before its start. A session started at or after the last ES anchor is the *current period's* (whether still open or already closed); a session open since before the last ES anchor belongs to the previous period, and the Daily Planning nudge re-arms for it while Evening Shutdown wins. This "qualifying session" rule — `started_at >=` last ES anchor — is the single test for whether the current period's planning has happened.

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

- A reference to the engaged Action (conceptually required; the stored column is nullable only to admit pre-Action-era logs, whose current-Action is unreconstructable, and logs whose Action was later deleted — the backend detaches with `ON DELETE SET NULL` rather than deleting the log — so a null there means "no Action attribution available", never a TimeLog that conceptually lacks an Action)
- A reference to the engaged Outcome (the Action's Outcome — retained so pre-Action-era logs and any Actionless edge still attribute at the Outcome grain; every time-spent total sums at this grain)
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
A scheduled interval — a start time and a duration — attached to a Plan entry, expressing *when within the session* the user intends to engage that Outcome. A property of the (FocusSession, Outcome) Plan membership, not a stand-alone entity: at most one per Plan entry, and it dies with the session. Review's `rollover` carries the *commitment* but never the Timebox; scheduling is redone each Planning phase against that day's calendar. A Timebox is an *intention*, not a record — actual engagement is captured by TimeLogs, and the gap between them is preserved as information. It is not a state axis: an Outcome with a Timebox keeps its Intent and List memberships unchanged.
_Avoid_: ScheduledTask, CalendarBlock, Slot, Event (Event is reserved for external-calendar entries), "scheduled" as a state

**Settled** *(derived predicate, session-scoped)*:
An Outcome on the open FocusSession's Review surface whose engagement in that session has reached a verdict. Either **(a)** its Completion is recorded, or **(b)** an Action of the Outcome was completed *within this FocusSession* and the Outcome has been re-clarified at or after that completion. Arm (b) is the session-scoped negation of **Stale** (GTD Core), so a Settled Outcome is by construction not Stale.

"Within this FocusSession" is session attribution, never a wall-clock window: the completed Action must carry a TimeLog attributed to the open session. Sessions are calendar-independent and may span days.

Settled says what the user has already *answered for this session*. It says nothing about List membership and writes nothing — an Outcome settled to "more work later" or "waiting" sits on its normal Lists (Next / Waiting For / Someday) exactly as its verdict left it. Its use is session-scoped: the Execution surface strikes off Settled Outcomes and stops offering them, and Review shows them in the summary rather than asking about them again. Two shapes deliberately do not settle — a **dismissed** re-clarify prompt (the Outcome genuinely still owes a re-clarification) and a Done on an **Actionless** Outcome (nothing was completed, so nothing settled).

Settled Outcomes group for the Review summary by a **presentation ladder** — Completion → `done`; Intent `maybe` → `someday`; a current Action → `next`; a PersonBlocker → `waitingFor`; otherwise `next`. The ladder is one heading per Outcome, *not* a statement of List membership: Next and Waiting For overlap by design, so a mutually-exclusive bucket could never equal it.
_Avoid_: Resolved / Resolution (spoken for — see Disposition's _Avoid_ and the ambiguity below), Handled, Closed

**Sprint** / **Break**:
Subdivisions of a TimeLog applying the Pomodoro discipline. A **Sprint** is a timed work block; a **Break** is the rest block between Sprints. The clock keeps running through both — Sprints and Breaks subdivide the TimeLog's rhythm without breaking its continuity. Purely a UI overlay and discipline aid — **not persisted as entities, not tracked in the model**. The only structural contact Pomodoro has with the rest of the system is the UI's pre-computed Sprint count for an Action, derived from `Action.time_estimate / Sprint duration` — and even that is presentational rather than required.
_Avoid_: PomodoroPhase, FocusBlock, WorkBlock

**Disposition**:
Where an Outcome that did not complete during the FocusSession stands at the end of it. Usually the user's own decision in the Review phase; on a **Settled** Outcome it is *implied* by the verdict already given in-session, because Review never asks about one. One of three values:

- `rollover` — pre-select this Outcome for the next FocusSession's Planning (user can deselect there). Rendered in UI copy as **"Carried over from last session"** — "last session", not "yesterday", because sessions are calendar-independent and may span days. The code identifier stays `rollover`; the Now screen's carried-over section reads the `rollover` union across both Disposition homes from the most recently closed session, shown only while no session is open.
- `leave` — return to its normal List membership; no special handling.
- `maybe` — set Intent to `maybe`, moving the Outcome to Someday/Maybe.

A Disposition is recorded per-(FocusSession, Outcome) pair — it is a property of the relationship between the session and the Outcome, not of either standalone. Applied to every non-completed Outcome surfaced in Review (the union of Plan members and off-Plan engaged Outcomes). Completed Outcomes need no Disposition.

**A Disposition may be implied rather than chosen.** A **Settled** Outcome was answered for during the session, so Review shows it in the summary instead of asking again — but it still leaves Review with a Disposition, minted at close from how it settled: `next → rollover`, `waitingFor | someday → leave`, `done → none`. An explicit choice always wins over an implied one. So a future reader of the record may find a `rollover` the user never tapped (ADR-0048).
_Avoid_: Resolution, Decision, Handling, Action (overloaded)

#### Relationships

- The **Plan** is a *commitment* set captured during the Planning phase; it does not auto-mutate during Execution. Off-Plan engagement is allowed and attributes to the session, but does not modify the Plan. The Plan-vs-actually-engaged gap is preserved as information — useful for retrospection, coaching, and future AI augmentation.
- **Focus** may point to any Outcome the user is engaging with, whether or not that Outcome is on the Plan.
- A **TimeLog** writes attribute to the open FocusSession (if one exists at engagement time) regardless of whether the engaged Outcome is on the Plan. If no FocusSession is open, the TimeLog is ad hoc — no session attribution.
- The **Review** phase surfaces every Outcome that was either on the Plan or engaged with during the session (the union), so neither off-Plan work nor planned-but-untouched Outcomes slip past disposition. Review splits that surface by **Settled**: Settled Outcomes are reported (grouped by how they settled) and take an implied **Disposition**; the rest are asked about one at a time.
- **Settled is session-scoped and changes no List membership.** It is derived from facts already recorded — the Outcome's Completion, its Actions' completions, the TimeLogs attributing them to this session, and `last_clarified_at` — so it is a read with no state of its own, nothing to migrate, and nothing to keep in step across Devices.
- A **Timebox** belongs to exactly one Plan entry (at most one per entry) and shares the Plan's lifecycle — created or edited during Planning (and adjustable during Execution), never surviving the session. Off-Plan engagement is by definition un-timeboxed. TimeLogs record what actually happened; Timeboxes record what was intended — the two are never reconciled destructively.
- **An Action may have many TimeLogs** over its lifetime — different engagement intervals on the same Action, possibly across multiple FocusSessions, possibly interspersed with engagement on other Actions within the same FocusSession. An Outcome's TimeLogs are the union of its Actions' TimeLogs.
- **The hierarchy is FocusSession → TimeLog → (Sprint+Break cycles).** A FocusSession is "from when the user sits down at the table to when they get up" and contains multiple TimeLogs (one per engagement interval). Each TimeLog is subdivided into Pomodoro Sprint+Break cycles at the user's chosen cadence as a UI rhythm; the cycles do not persist or break the TimeLog's continuity.

#### Flagged ambiguities

- "Plan" is polymorphic in Jeeves' vocabulary. The **FocusSession's Plan** (this context) is a List of *Outcomes* selected for one session. An **Outcome's plan** (GTD Core) is its List of *planned Actions* — the user's externalised "what's next" thinking for a single Outcome. Different scopes, same English word; context disambiguates. If the clash bites in code or copy, the per-Outcome notion can be rewritten as "the planned Actions of an Outcome" without losing meaning; the per-session notion is the one that needs the short name.
- **There is no "pause" in the engagement model.** An earlier implementation surfaced a pause control which was actually an unlabelled "start break" — corrected in #246 / PR #252 (commits a95c7ab, 2efab56, bfc6d66). Residual `pause` / `isPaused` / `resume` references may persist in code, copy, or older docs; treat any such reference as a candidate for removal. The two real intents the misnomer collapsed: *abandon sprint* (Stop) and *take a break* (Start break — a phase transition, not a clock suspension).
- **"Resolution" is spoken for, and the Review step still says it.** Disposition's `_Avoid_` list rejects Resolution, but the Evening Shutdown step-1 code uses it *to mean Disposition* — `_TaskResolutionCard`, `_ResolutionButton`, the step title "Resolve Unfinished". So "group the summary by resolution" would read in this codebase as "group by Disposition", which is exactly backwards; the summary groups by **Settled**. Renaming those identifiers and that copy to Disposition vocabulary is outstanding.
- **"Settled" is a homonym across contexts.** In Engagement it is the per-session verdict predicate above. In **Sync Integrity** it describes a quarantined op whose gap claimant arrived, and a conflict that has been decided. Different bounded contexts and no shared code path, so both usages stand — but a reader meeting one after the other should know they are unrelated.

### Ceremony Framework

Mechanics — visibility predicates, Trigger definitions, queue ordering and surface
mappings — live in [docs/CEREMONIES.md](docs/CEREMONIES.md).

#### Language

**Ceremony**:
A guided activity the user performs with the app's facilitation: the app surfaces structure, prompts and sequencing; the user provides the decisions. A core domain concept — *what* the user is doing — independent of *how* the app surfaces it. Commonly implemented as a Wizard, but a single modal, inline form or voice flow would be the same Ceremony. Each **performance** runs not-started → in-progress → terminated, and terminates as either **completed** or **abandoned**; the distinction is what Triggers read.
_Avoid_: Ritual (narrower — see below), Wizard (an implementation form, see Implementation tier), Flow

**Ritual**:
A Ceremony the app treats as integral to the user's practice — strongly suggested, regularly nudged for, expected to recur. Daily Planning is a Ritual; an ad-hoc clarification of a one-off Capture is just a Ceremony. The designation adds a *discipline overlay*, not a separate kind of activity. Today that overlay is a **Cadence** and a **Nudge**; other shapes are conceivable (streaks, partner accountability) but not modelled, and the abstract layer stays informal until a second shape is needed. A Ritual also carries a **priority**, which positions its Nudge in the queue.
_Avoid_: Habit, Practice, Routine (none carry the "integral to the app's discipline" connotation precisely)

**Trigger**:
An autonomous predicate-with-edge-detection that fires its Nudge to visible when the predicate transitions false→true. A Nudge has one or more; they are independent of each other and of Cadence period semantics, and each owns its full domain logic — including any "is the Ritual stale enough to nag again?" check. A predicate may consult any domain state, and may carry world-state preconditions that gate whether the Ritual makes sense at all.
_Avoid_: Event (Triggers are predicates with edge semantics, not point-in-time events), Condition (too generic), Predicate (a Trigger *contains* a predicate but adds edge-detection and Nudge-firing)

**Nudge**:
The app's mechanism for suggesting a Ritual — a contextual reminder that the disciplined Ceremony is due. Belongs only to Rituals; ad-hoc Ceremonies are user-initiated and need none. Its visibility is *computed*, never stored; the only persisted facts are the user's **dismiss** (scoped to the current firing) and **snooze** (time-bound). **In-progress hygiene** — no Nudge of a Ritual while a performance of it is underway — is the one centralised, content-independent rule the Nudge model carries.
_Avoid_: Reminder (a separate concept — see ambiguities), Prompt, Suggestion (overloaded with AI surfaces)

**Cadence**:
The recurring schedule that determines when a Ritual is due, carrying a **shape** (the calendar pattern — daily, weekly, every-N-days, which also drives cadence-flavoured copy) and an **anchor** (the moment within the shape on which period boundaries land). The period runs anchor-to-anchor (ADR-0008). Belongs only to Rituals; ad-hoc Ceremonies have no Cadence.
_Avoid_: Schedule (overloaded — implies fixed times of day), Frequency (less precise), Period (too generic), Rhythm (informal)

**Nudge queue**:
The priority-ordered list of currently-visible Nudges across all Rituals. It exists *above* individual Nudges — each Nudge's predicate stays independent of other Rituals — because single-occupancy surfaces need an unambiguous answer to "of the visible Nudges, which do I show right now?"
_Avoid_: stack, list (too generic), priority list (acceptable but Nudge queue is the canonical term)

#### Relationships

- A **Ritual** is a **Ceremony** with a *discipline overlay*. Removing the Cadence and Nudge demotes it to a plain Ceremony; adding them promotes one.
- A **Nudge** is composed of one or more **Triggers** plus persisted dismiss/snooze state, and belongs to exactly one Ritual.
- A **Trigger** is autonomous — independent of other Triggers and of Cadence period semantics. The **Cadence Trigger** is the canonical shape; content-state Triggers are the others.
- **Completion** of a performance is a Ceremony fact, not a Nudge state. Triggers consult it per their own predicates; the Nudge does not centralise it.
- A **Trigger** may read state from other contexts. The FocusSession-lifecycle gates live inside the relevant predicates, never as separate Ritual-level rules; the Engagement context's invariants are the ground truth Triggers read.
- A **Nudge** has zero or more *surfaces* (**Banner**, **Notification**), which are pure projections. Adding or removing one does not change what a Nudge is.
- A **Ceremony** may be implemented as a **Wizard** or any other UI form; the form is independent of the concept.
- **Disposition** (Engagement) is the per-Outcome decision used inside Review-type Ceremonies. Other Ceremonies may introduce their own decision vocabularies.

#### Flagged ambiguities

- **Nudge** (this context) and **Reminder** (forthcoming, GTD Core) are different concepts. A Nudge targets a *Ritual* — "it's time for your weekly review". A Reminder targets an *individual Action* — "remind me to call John at 5pm". Different scopes, triggers and lifecycles; do not collapse them into one primitive even though both surface as OS notifications.

### Sync

Sync is responsible for bidirectional offline-first replication of one User's data across their Devices. Most of its vocabulary is technical and lives in the Implementation tier; the user does not think in sync vocabulary — they expect data to follow them across devices and the app to work without connectivity, without naming the mechanisms that achieve either. What belongs in this section is the one term the user *does* meet, plus the Relationships subsection — the architectural discipline that keeps Sync from leaking upward into the contexts above it.

#### Relationships

- **Sync types do not appear in GTD Core / Engagement / Ceremony Framework function signatures.** The dependency direction is strictly one-way: those three contexts speak Drift/in-memory entities; Sync mechanically replicates those entities without adding semantics. The seam is the capture binding — a DAO write path describes *what changed* and never who is listening, which is what lets an un-enrolled device run the same write paths and author nothing. Any change that would add a Sync-tier type (a `SyncClient`, an `Op`, a `Workspace` id, an HLC) to a method signature in another context is the warning sign.
- **Sync is additive — the app's offline behaviour does not depend on a working Sync layer.** If the server is unreachable, authored ops sit in the durable outbox and the user continues to work; the next flush drains it. A device that has never enrolled authors nothing at all and remains a fully functional single-device GTD store. That is a **steady state, not a stage**: it holds whether or not the device is signed in, for as long as the user likes, and nothing in the app routes them out of it. Enrolling is offered — in Settings, and on the first-launch card — and taken by choice (#673).
- **Nor does the *session*.** The account id is what every Workspace id, the escrow slot and the Grants derive from, so clearing a session is not merely a re-prompt for a password — it unbinds the capture seam and drops the session's ops. A Device therefore stays signed in and authoring unless the backend itself authoritatively says otherwise.
- **Each context owns what is replicated.** GTD Core decides Outcomes, Actions, Tags, etc. are replicated; Engagement decides FocusSessions and TimeLogs are; Ceremony Framework has nothing structural to replicate today. Sync mechanically follows those choices but does not influence them.
- **Local-only state is not replicated by design.** Sprint timer state in SharedPreferences, ephemeral UI focus, and per-device preferences (when added) stay local. Each context's Implementation tier specifies what is local-only versus replicated.
- **Conflict resolution defaults to Last-Write-Wins (LWW).** Acceptable for the current single-user-many-devices model; collaboration features (when they land) may require operation-based or CRDT-style resolution on the shapes they touch. For `user_preferences`, a per-key strategy registry refines the default: a few keys need non-LWW arbitration, and the default must be non-destructive for future keys. Matrix in [docs/SYNC.md](docs/SYNC.md).
- **A User participates in one or more Workspaces — two implicit ones today.** Participation is the set of grants held by that User's keyholders, not an ownership column on the Workspace. An **Area** belongs to exactly one Workspace; a Workspace holds many. Everything else a Workspace contains (Captures, Outcomes, Actions, Tags — and the Person, Area, and Label entities Tags back — FocusSessions, TimeLogs) reaches its Workspace through the Area or, being Area-less, sits directly in it.
- **A FocusSession belongs to exactly one Workspace.** A day that spans Workspaces is a *client-side union* of that day's per-Workspace FocusSessions, rendered together; there is no stored cross-Workspace Plan. The union is possible because a Device holds every one of its User's keys — see the isolation rule in the **Workspace** entry.
- **`user_preferences` is User-global, not per-Workspace.** It lives in its own implicit Workspace — one of the two every User has, alongside the default GTD one — which every Device is granted and no Service ever is. The boundary is structural rather than a policy: a Grant to a non-Device member is refused in that Workspace on both sides, so a preference cannot leak through a Service grant.
- **A Member belongs to at most one User.** A **Device** belongs to exactly one; a **Service** to none (registered, not owned). A **Grant** joins one Member to one Workspace with one role, and a wrapped key fulfils that Grant for one epoch. A User-level signing root anchors the whole control plane; **Recovery** escrows it under the passphrase and is not a Member.

#### Flagged ambiguities

- **Encryption is off until an owner turns it on**, per Workspace. The conceptual model treats a Workspace as encrypted; a Workspace that has never run the ceremony is not, and its content ops are plaintext. The gap is deliberate and named rather than papered over.
- **A Workspace with a live-granted Service cannot rotate its epoch key**, because a Service holds no per-User key-exchange subkey to wrap to. The ceremony refuses rather than publishing a rotation the Service cannot follow. Revoking the Service is the only way through today.

## Implementation

**User** *(an authenticating identity)*:
An identity that can authenticate against the Jeeves backend, carrying either an email + password or a Solana public key (`users` table). The unit of ownership for everything the backend stores. Distinct from **Person** (GTD Core): a Person is a name inside one User's store, with no login and no existence outside it. The two are orthogonal — most Persons never become Users, and a User is not thereby a Person in anyone's data. Jeeves has no tenancy or billing layer above User: there is nothing a User belongs to.
_Avoid_: Account (no tenancy wrapper exists — User is the identity), Owner (names a role in a relationship, not the entity), Person (a distinct GTD Core concept)

**Workspace** *(a complete, isolated GTD system)*:
The unit of partition, encryption, and replication — one Inbox, one set of Areas, one Next List, one Plan. Not a subset of a User's data but a whole system, analogous to Allen's advice to keep a functional workstation at the office and another at home, each with its own in-tray and filing (GTD ch. 4). **A Workspace is one mind's system**: its Inbox, Next List and Plan hold personal *stance* — Intent, clarification stamps, what the User chose to do today — which has no shared meaning across two people. The standing position is therefore **delegation over co-ownership**: work is handed to another User by copying the Outcome into *their* Workspace while the sender keeps a PersonBlocker and tracks it on Waiting For. A Capture always lands in the current Workspace, unprompted — capture must never ask a question; relocating it is a clarification verdict alongside carve / merge / discard. Isolation is a property of storage and membership, not of the User's view: a client holding every key its User holds may freely render across Workspaces. Mechanics in [docs/SYNC.md](docs/SYNC.md).
_Avoid_: Vault (password-manager connotation), Space (reads as a synonym for Area), Realm, Partition, Tenant, Desk (the physical metaphor is the origin, but "where I am" is **Context**'s job)

**Member** *(a keyholder that can participate in Workspaces)*:
An entity that can hold Workspace keys, author Ops, and authenticate to the sync server. Two kinds. A **Device** is owned by exactly one User and is granted every Workspace its User participates in, automatically. A **Service** is *registered, not owned* — it belongs to no User, and Users relate to it only through Grants, one named Workspace at a time.
_Avoid_: Peer, Keyholder, Client (transport term), Participant (a Grant role), Account

**Grant** *(the membership fact: Member × Workspace, with a role)*:
The signed authorization fact "this Member participates in this Workspace with this role", recorded in the log rather than as bare server state. The Grant *is* membership. Its **role** fixes what the Member may emit: **owner** (content and control), **participant** (content), **compactor** (history re-assertion — the most-trusted role), **suggester** (suggestions only — the least-trusted, and the AI Service's default). A Grant whose key has not been delivered is an *orphaned grant*: a nameable, healable state, not a mystery decryption failure.
_Avoid_: Membership (heavier synonym), Share, Permission (the role is the permission; the Grant is the fact)

**Recovery** *(the passphrase escrow — not a participant)*:
How a new Device bootstraps with only the User's passphrase and no second device online: a root-signed, monotonically versioned blob held server-side, opened by a passphrase that never leaves the device. It is a property of the User, not a Member — no identity, no cursor, no authorship. The passphrase's entropy is the E2EE ceiling against a stolen-ciphertext adversary, so a weak override warns rather than silently accepts.
_Avoid_: Backup (it recovers keys, not data — data recovery is any surviving device's local store), Recovery member (it is not a Member)

**Integrity Alarm** *(a standing accusation, or a standing local condition that will never heal)*:
What a Device records when the log it was served cannot be reconciled with the chains bound into it, or with the keys it holds — a withheld op, a forked stream, a rollback of its own writes, a signature that does not verify. **An accusation standing is not the same as the User being told something is wrong**, and most standing accusations are records of the app working: only four of the eighteen kinds mean something of the User's is stuck or lost, and only those turn the indicator red. **A refusal is never an error to the User** — the bytes were refused, which is the outcome the rule exists to produce. A key that has not arrived yet is a delivery gap that heals, never an accusation. Kinds, classes and resolution in [docs/SYNC.md](docs/SYNC.md).
_Avoid_: Sync error (a transport failure of one attempt is not an accusation), Conflict (merge conflicts are resolved by the merge strategy and are not integrity events), Dead Letter (retired vocabulary, for an unrelated mechanism), Rejected op (a rejection is the server's answer to an append, not the receiver's record)

**Tag** *(backs the GTD Core concepts Person, Area, Label, and legacy Context)*:
The shared storage row backing several conceptual entities, discriminated by a `Tag.type` field. Outcome ↔ Tag links are stored in a `TodoTags` join table; the join carries no role information of its own (its semantics depend entirely on the linked Tag's `type`). The user does not think in terms of Tags — they think in terms of the domain entities Tag backs. Physical-world equivalent: a folder, sticky note, or label-maker — a categorisation mechanism, not a domain concept. Each conceptual entity Tag currently backs has its own Conceptual-tier glossary entry; this entry exists so the code's `tags` table has a name in this glossary without implying that "Tag" is part of the user's mental model.

**A Tag has two identities, and only one of them is the primary key.** `id` is the op-log identity — client-random, so it is what the sync substrate names the entity by. `(name, type)` is the *user-facing* identity: two rows with the same pair are one Person, one Area, one Label or one Context as far as the user is concerned. Because ids are random, two Devices each creating "Alice"/`person` while apart mint two entities for one pair, and both are real — a transient, converging state, not corruption. They fold onto one as the Devices converge. Seeing two "Alice" entries on a freshly reconnected Device is convergence; still seeing them once synced is a bug. Fold mechanics in [docs/SYNC.md](docs/SYNC.md).
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

**Wizard** *(one possible implementation form for a Ceremony)*:
A UI/UX pattern for guiding a user through a structured multi-step input flow, carrying the affordances the pattern implies: next / back / skip, a step indicator, and a terminal step. **One possible form a Ceremony takes, never a synonym for one** — Daily Planning is a Ceremony that is *currently implemented as* a Wizard, and could be re-implemented as a single scrolling page without becoming a different Ceremony. Shell, steps and affordances in [docs/DESIGN.md](docs/DESIGN.md).
_Avoid_: Stepper, Carousel, MultiStep, Flow (Flow is used colloquially but is broader)
