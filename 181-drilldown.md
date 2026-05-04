# Conversation transcript (visible turns only)

Source: `/Users/phoenix/.claude/projects/-Users-phoenix-Documents-tmayad-Jeeves/30713c87-db56-43bf-983d-859a3e0b4d14.jsonl`

## user

180 & 181 seems like best choice. Next question is which order should we tackle that in.
Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time.

If a question can be answered by exploring the codebase, explore the codebase instead.

---

## assistant

Let me read both issues first so I can pose the ordering question with grounded context.

Good, both grounded now. Here's my first question:

---

## Question 1: Order — #181 first, or #180 first?

**My recommendation: #181 (blockers domain model) first.**

Reasoning:

The planning ritual's surfaces all care about blockers — Clarify must let you record "Alice hasn't replied," Review Next Actions must hide tasks whose blockers aren't satisfied, the capacity bar must exclude blocked work, Today's Tasks must show *why* a task can't be acted on. If we redesign the ritual UX before fixing the model, the ritual will assume today's collapsed FSM (`waiting_for` ∨ `scheduled` ∨ `blocked`, one at a time) — and we'll have to reopen every screen decision when blockers become polymorphic.

Counter-argument I considered: the three concrete gaps in #180 (drawer routing, back navigation, energy-step skip) are orthogonal to blockers. But you explicitly said "not to be fixed individually — inputs into a planned redesign," so #180's scope is the whole ritual, not those three bugs alone. The whole ritual interacts with blockers.

Risk of going #181 first: you said #181 is "domain-model thinking" but blockers do have UX surface — anywhere a blocker is created, displayed, or cleared. We'd need to scope #181 to model + minimal evaluation semantics, defer the UX of *displaying/creating* blockers to whatever epic touches that surface (could be #180's redesign).

**Concretely: #181 produces a ratified schema + actionability predicate; #180 then redesigns the ritual *aware that blockers exist*.**

Do you agree, or do you want #180 first?

---

## user

180 with increased scope of integrating the UI/UX surface of 181 is the right call. As you pointed out, 181 UI/UX is tightly integrated with the focus session flow. So we can't build either one in isolation and expect to shoe horn the other later. OTOH, we do have a workflow for daily planning, even if it is suboptimal. We can still build 181 and jugaad an interface into it fully expecting it to be replaced in a future run of 180.

---

## assistant

Confirmed: build #181 with placeholder UX (jugaad), then #180 redesigns the ritual + the blocker surface together as a coherent pass. So next questions are all about #181's model shape.

---

## Question 2: What variants ship in #181 v1?

The issue lists five variants. They have different data-readiness, different complexity, and different downstream dependencies:

| Variant | Existing data to migrate | Net-new infra needed | Notes |
|---|---|---|---|
| TaskBlocker | Yes (`blocked_by_todo_id`) | None — just FK | Open question: belongs here or under future Project? |
| PersonBlocker | Yes (`waiting_for` text) | None — text + manual clear | Largest replacement of FSM |
| TimeBlocker (specific) | Yes (`scheduled` FSM state has implicit time?) | None — `target_time` field | Replaces `scheduled` state if it has a date; need to verify |
| TimeBlocker (recurring) | None — net new | RRULE-subset OR custom enum modelling | "Open mic Tuesdays" — can it wait? |
| LocationBlocker | Partial (`locationId` exists on todos but isn't a blocker) | Geofence event source (#46 still in design) | No infra yet |

**My recommendation: v1 = TaskBlocker + PersonBlocker + TimeBlocker(specific). Defer TimeBlocker(recurring) and LocationBlocker.**

Reasoning:

- The first three all have existing data on `todos` to migrate cleanly. Picking them lets v1 fully retire the `waiting_for` / `scheduled` / `blocked` FSM states and the side fields, which is the whole point — we don't want to half-migrate and leave the FSM half-alive.
- TimeBlocker(recurring) needs its own RRULE-vs-enum modelling exercise; bundling it inflates v1 with a sub-debate that's separable.
- LocationBlocker depends on geofencing infrastructure that doesn't exist yet and on `[Design] #46` which is still open. If we ship it now, we ship a non-functional variant.
- The TaskBlocker-vs-Project open question I'd answer pragmatically: **model as TaskBlocker now; if Project lands later and subsumes it, that's a future migration**. Leaving `blocked_by_todo_id` as an island while every other field gets folded into Blocker is the worse outcome.

Before I ask: let me verify one assumption. The table claims `scheduled` FSM state implies a time field. Let me check.

Important correction: I was wrong about TaskBlocker having existing data. The `blocked` state and `blocked_by_todo_id` column were **already stripped** in migration 0012 (PR B, #190). `docs/REQUIREMENTS.md:27` explicitly says: "Dependency tracking between tasks is deferred to TMaYaD/Jeeves#181."

So the corrected picture:

| Variant | Existing data | Status today |
|---|---|---|
| TaskBlocker | None — already stripped | Net-new feature |
| PersonBlocker | `waiting_for` text | FSM half-alive, needs to land somewhere |
| TimeBlocker (specific) | `scheduled_at` + `scheduled` FSM state | FSM half-alive, needs to land somewhere |
| TimeBlocker (recurring) | None | Net-new |
| LocationBlocker | None | Net-new, depends on #46 geofencing |

**Updated recommendation: same answer (v1 = TaskBlocker + PersonBlocker + TimeBlocker-specific), even stronger reasoning.** The codebase already pre-decided that #181 is where TaskBlocker lives — `blocked_by_todo_id` was stripped *to make room for* this epic. PersonBlocker and TimeBlocker(specific) are the FSM cleanup we owe ourselves. Recurring + Location are clearly separable net-new features.

Do you agree with v1 = {TaskBlocker, PersonBlocker, TimeBlocker(specific)}, deferring TimeBlocker(recurring) and LocationBlocker?

---

## user

Defer task blocker. It's UX will be limited to showing up in daily planning ritual when there are no blockers and finding a good UI to show pending blockers in the detail page. OTOH, the implication of the feature is in direct comepetition with the "projects" in traditional GTD. I need to dogfood the app for some significant time to make sure I get that right. Only risk would be potential high touch point during the clarify step. That's a risk I'm willing to take.

The others, we can deal with now. But each requires a careful consideration on how to do them. So it's better to take it up one at a time than attempt all together. That being said, the UI/UX we build now is going to be throw away, so we can go ahead and build the plumbing right away, including the task blocker. One at a time.

---

## assistant

Got it. Plan locked:
- **Plumbing** for the polymorphic Blocker scaffold + all variants (incl. TaskBlocker) lands now
- **UX** is jugaad/throwaway, formal UX in #180
- **TaskBlocker UX** deferred entirely (minimal surface — needs dogfood time before committing on the Project-vs-Blocker question)
- **Variants sequenced one-at-a-time**, each its own consideration pass

Next foundational question. Let me peek at existing patterns first.

Useful precedent found. The `Reminder` table at `backend/app/todos/models.py:176-190` already uses single-table-with-discriminator: `type: "time" | "location"` + nullable variant columns (`scheduled_at`, `location_id`, `on_arrival`, `on_departure`). And the codebase has zero use of SQLAlchemy joined/single-table polymorphic inheritance — `polymorphic_identity` and `polymorphic_on` aren't used anywhere.

Also corrected: I was wrong about TimeBlocker having existing data. `scheduled` state was collapsed in 0011 preserving `due_date`, but `due_date` is a deadline (when it must be done *by*), not a deferral (don't show *until*). So TimeBlocker(specific) is net-new data too. Only PersonBlocker has live remnant data (`todos.waiting_for` text).

---

## Question 3: Schema shape — single table with discriminator, per-variant tables, or joined inheritance?

| Option | Shape | Pros | Cons |
|---|---|---|---|
| **A. Single table + discriminator** | One `blockers` table with `type` + nullable variant columns | Matches `Reminder` precedent; one PowerSync bucket; trivial actionability query | Many nullable columns; CHECK constraints policed in app layer |
| **B. Per-variant tables** | `task_blockers`, `person_blockers`, `time_blockers`, … | Clean per-variant schema; no nullable columns | UNION to fetch "all blockers for task X"; N sync buckets; new variant = new migration; actionability joins N tables |
| **C. Joined inheritance** | `blockers` (id, type, satisfied_at) + `*_blocker_details` per variant | Normalized; SQLAlchemy joined-inheritance fits | Two-table write per blocker; codebase has no precedent for this pattern; overkill for variants this small |

**My recommendation: Option A (single table + discriminator).**

Reasoning:

1. **Precedent.** `Reminder` does exactly this — `type: "time" | "location"` + nullable variant fields. Following the same pattern reduces cognitive load and lets us reuse mental models for sync rules and Drift mirroring.
2. **Actionability is hot path.** `SELECT 1 FROM blockers WHERE todo_id=? AND satisfied_at IS NULL LIMIT 1` is the single query that gates every "is this actionable?" check across Next Actions, Today's Tasks, capacity bar, etc. Single table makes this trivial; UNION (Option B) makes it a structural cost paid forever.
3. **PowerSync ergonomics.** One bucket definition, one sync rule, one Drift table, one Freezed sealed class hydrated from a discriminator. Option B inflates this 4–5×.
4. **Variants are shallow.** Each variant has 1–3 fields. The "nullable column sprawl" cost is ~5–6 nullable columns total — manageable.
5. **No new SQLAlchemy patterns.** The codebase doesn't use polymorphic inheritance; Option C would introduce that pattern just for this.

The Flutter side becomes: Drift `Blockers` table with the same shape → Freezed `sealed class Blocker` with N variants constructed by reading the discriminator. Storage shape ≠ domain shape; that's fine.

Do you agree with single-table-with-discriminator?

---

## user

Don't jump into implementation detail with tables, schema design and SQL queries yet. If we get the domain modelling right, good schema and data shapes will follow.

---

## assistant

You're right — I jumped a level. Backing up to domain.

---

## Question 3 (redo): The nature of "satisfied" — is it homogeneous across variants?

When you read the five variants, "satisfied" doesn't mean the same thing across all of them. Two distinct shapes emerge:

**Event-shaped satisfaction** — happens once, persists forever after.
- *PersonBlocker:* "Alice replied" — flips once, stays cleared.
- *TimeBlocker (specific):* "Nov 30 has passed" — once true, always true.
- *TaskBlocker:* "Task A is done" — once true, stays true (modulo undo, which is its own question).

**Predicate-shaped satisfaction** — continuously evaluated, can flip on and off as world state changes.
- *TimeBlocker (recurring):* "Now is Tuesday or Thursday" — true Tue/Thu, false rest of week.
- *LocationBlocker:* "I am at home" — true while I'm home, false when I'm out.

This isn't an implementation distinction; it's a **conceptual** one. An event-shaped blocker has a moment where it's satisfied, and that's part of the task's history. A predicate-shaped blocker doesn't have a moment of satisfaction — it has *windows of actionability*. The same task is actionable Tue/Thu but not Wed.

This affects how Blocker behaves in the domain:

- **History:** event-shaped blockers can record *when* they cleared. Predicate-shaped can't — they have no clearing event.
- **Notifications:** "Alice replied — task X is now actionable" is a meaningful event. "Tuesday rolled around — task Y is now actionable" is also a meaningful event, but it's recurring and may need to be suppressed if seen before.
- **Display in detail page:** event-shaped shows "Cleared by you on Nov 14"; predicate-shaped shows "Actionable Tue/Thu."
- **Cancellation:** does the user cancel a satisfied blocker? Re-block it? For event-shaped, "undo clear" is meaningful. For predicate-shaped, there's nothing to undo.

**My recommendation: model these as two distinct domain concepts, not one.**

- A `BlockingCondition` (or whatever we call it) is the umbrella concept on a task: "this task can't be acted on right now because of X."
- One sub-concept: **Pending Resolution** — something that hasn't happened yet but will, and we're waiting for it. PersonBlocker, TimeBlocker(specific), TaskBlocker. These can be "cleared" (event).
- Another sub-concept: **Context Requirement** — a condition that must hold *at the moment of action*. TimeBlocker(recurring), LocationBlocker. These don't clear; they're either currently satisfied or not.

Same AND-semantics across both ("the task is actionable iff all its conditions are met right now") but different lifecycles, different UX affordances, different mental models.

The alternative — collapsing them into one concept with a "satisfied" predicate — works for engineering, but loses the conceptual handle the user needs in the UI: "what am I *waiting for*?" (resolutions) vs "where/when *can* I do this?" (context requirements). GTD itself has these as different categories: waiting-for vs contexts.

Do you want one concept (Blocker, satisfied predicate) or two (Pending Resolution + Context Requirement)?

---

## user

Keep the exploration focused on domain modelling.

---

## assistant

You're right — I leaked into UX. Re-posing in pure domain terms:

---

## Question 3 (re-redo): Is "Blocker" one concept or two?

In domain terms, the variants split by their **temporal shape of satisfaction**:

**Type A — has a clearing event.**
- PersonBlocker: there is a moment when Alice replies. Before that moment: blocking. After: cleared, permanently.
- TimeBlocker (specific): there is a moment when Nov 30 arrives. Before: blocking. After: cleared, permanently.
- TaskBlocker: there is a moment when task A is marked done. Before: blocking. After: cleared, permanently (modulo task-undone, which is a separate question).

**Type B — has no clearing event.**
- TimeBlocker (recurring): there is no moment of clearing. The condition "now is Tuesday" is satisfied during some intervals and not others. Tuesday becoming Wednesday is not a clearing event — it's a return to blocking.
- LocationBlocker: same shape. Walking into the home satisfies the condition; walking out re-blocks.

The domain question: is this difference essential, or incidental?

**Essential view (two concepts):**
- A blocker of Type A has a *resolution lifecycle*: pending → resolved. Once resolved, the resolution is a fact in the task's history.
- A blocker of Type B has no resolution. It expresses a *standing condition* on when the task can be acted upon. It is never "done with."
- A task with only Type A blockers, all resolved, becomes permanently actionable.
- A task with any Type B blocker, even when all Type A are resolved, has its actionability oscillate over time — never permanently actionable, only sometimes-actionable.

**Incidental view (one concept):**
- All blockers are predicates over current world state. PersonBlocker's "world state" includes "has Alice replied" (a stored fact). TimeBlocker(specific)'s world state is "current time vs target time." TimeBlocker(recurring)'s is "current weekday." LocationBlocker's is "current location."
- Under this view, Type A's "clearing event" is just a derived consequence: their predicates happen to be monotonic (once true, always true). Type B's predicates are non-monotonic.
- The task is actionable iff all blocker-predicates are currently true.

**My recommendation: essential view — two concepts.**

Reason: monotonicity is not an implementation detail; it changes what the task *is* in the domain. A task whose blockers are all monotonic is on a trajectory toward being actionable — every clearing event moves it closer, irreversibly. A task with a non-monotonic blocker is not on any trajectory; it has standing conditions on its execution. The user's relationship to those two kinds of tasks is different: one is a thing being unblocked, the other is a thing whose execution is contextually scoped.

Conflating them under "predicate" is technically faithful but loses this. The domain has two shapes of "can't act yet" and ought to name them.

Do you accept the two-concept split?

---

## user

I agree. One is a "context" of actionability and another is a "blocker". What's worth exploring further is how we should handle something like the following use case:
"Waiting for trixy" -> "Trixy replied with document" becomes "review trixy's document" on my plate. "Trixy didn't reply" becomes "follow up with Trixy" on my plate. After I review the document, I can send it back to Trixy for revision and it becomes blocked on her again. None of these individual "actions" are things to get done in the true GTD sense because there things have a desired outcome. So how do we handle this? Do we have a task that moves between waiting for and next along with "actions"(forgot the GTD term for it) being surfaced some how? Or do we spawn tasks from tasks?

---

## assistant

This is the heart of the GTD modelling question. The term you're reaching for is **next action** in service of an **outcome** (or project, in GTD vocabulary).

In domain terms the question is: **what is the persistent identity?**

---

## Question 4: When the user is "doing the Trixy thing," what is the entity that persists across all the back-and-forth?

Three coherent answers:

**(A) The entity is the outcome. Actions are transient states of it.**

A Task is an outcome ("get document reviewed by Trixy"). It has a *current next action* and a history of past next actions. The Task does not complete when an action completes — it completes when the *outcome* is achieved.

- "Send doc" is done → Task isn't done; user is prompted to clarify the new next action ("wait for Trixy") → Task enters waiting state.
- "Wait for Trixy" resolves (she replied) → user clarifies new next action ("review document").
- After review → user clarifies new next action ("send revisions") → loops back.
- Eventually the *outcome* "document is reviewed" is achieved → Task is marked done.

The Task's identity is the outcome. Actions are the moving part.

**(B) The entity is the action. Outcomes are emergent from chaining.**

Each action is its own Task. "Send doc," "Review reply," "Send revisions" are separate Tasks. They may or may not be linked to a parent. The outcome lives in the user's head (or in a parent entity if we introduce one — Project).

- "Send doc" Task is done → user creates "Review reply" Task (possibly auto-spawned from a waiting-for resolution).
- The chain of Tasks IS the project, implicitly.

This is what current model already supports (every Task is an action). It can express the Trixy flow but loses the outcome as a first-class concept.

**(C) The entity is the action AND there's a parent outcome (Project).**

Two levels: Project = outcome (the persistent thing); Task = action (transient, child of Project). One Project has many Tasks over time. Waiting-fors hang off the Project, not individual Tasks.

This is GTD orthodoxy. It's also exactly the Project entity you wanted to defer — so picking this answer reopens that decision.

---

**My recommendation: (A) — the Task is the outcome.**

Reasoning:

- It honors your decision to defer Project. The Project concept comes for free at the Task level: every Task already represents a persistent outcome, with a moving next-action attached. We don't need a second entity tier.
- It cleanly answers "do we spawn tasks from tasks?" — **no**. The Task persists; only the next-action evolves.
- It cleanly answers "how does waiting_for relate to next?" — they are *states of the same Task's current next-action*, not different Tasks.
- It maps to GTD's central insight: the only thing worth tracking persistently is the outcome; the next action is whatever moves the outcome forward right now.
- "Done" gets a clearer meaning: a Task is done when its outcome is achieved, not when one action under it is completed. This is a sharper invariant than today's model.

The cost: today, Task titles are written in action-language ("Send doc to Trixy"). Under (A), Task titles drift toward outcome-language ("Get document reviewed by Trixy"). Most one-shot tasks ("buy milk") still work — for them, action-language and outcome-language collapse. Multi-step tasks need the user to think in outcomes.

Implication for blockers: a blocker (or context) attaches to *the current next action* of a Task, not to the Task itself. When the next action changes, the blockers reset — the new next action has its own blockers (often: a fresh waiting-for).

Do you accept (A) — Task as persistent outcome, current next-action as the moving part?

---

## user

<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>

<command-name>/effort</command-name>
            <command-message>effort</command-message>
            <command-args>medium</command-args>

<local-command-stdout>Set effort level to medium: Balanced approach with standard implementation and testing</local-command-stdout>

Yes, But not just because it pushes project downstream. The key is the core GTD insight: the only thing worth tracking persistently is the outcome; the next action is whatever moves the outcome forward right now. We need to respect and make it a core tenet of our design language. We don't just build a tool and leave it up to the user. We provide guard rails to supercharge the user. This tenet also becomes more powerful after AI milestone where AI can remind the user to follow up or delegate automagically.

---

## assistant

Saving the design tenet.

Saved. Tenet noted as foundational.

---

## Question 5: Is "next action" a domain entity, or a property of Task?

Q4 said the Task is the persistent outcome and the next-action is the moving part. That leaves a sharp question about what kind of *thing* the next-action is.

**(a) Next-action is a value/property of Task.** Task has fields like `currentNextActionDescription`, `currentNextActionState ∈ {active, waiting}`. When the next-action is completed, those fields are overwritten. No history is kept; the past next-actions vanish.

**(b) Next-action is a domain entity in its own right.** A Task has many NextActions over its lifetime; exactly one is "current." Each NextAction has its own identity, description, state (active/waiting/done), creation time, completion time, and its own attached blockers/contexts. Completing a NextAction transitions it to done and creates the next NextAction (new entity). The Task accumulates a history of NextActions over time.

---

**My recommendation: (b) — NextAction is a domain entity.**

Reasoning, tied to the tenet just saved:

1. **The tenet demands history.** "AI can remind the user to follow up" requires the AI to know what next-actions have been tried, when, and how they resolved. "Auto-detect stalled outcome" requires knowing the time-since-last-NextAction-completed. Both need a queryable record of past NextActions, which (a) erases.

2. **Blockers attach naturally.** Pending Resolutions ("waiting for Alice") and Context Requirements ("at home") are not properties of the *Task* — they describe a specific NextAction's state. If the next NextAction is "review document," it has different blockers than the previous "send document." Attaching blockers to the Task forces a wholesale reset every time the next-action changes.

3. **Lifecycle clarity.** A NextAction has a clean lifecycle: created → active or waiting → done (or abandoned). A Task has an orthogonal, longer lifecycle: created → … (many NextActions) … → outcome achieved. Two entities, two lifecycles. (a) tries to fold both into one and ends up with a Task entity that mutates incoherently.

4. **Domain handles for the guardrails.** "What was the last thing you tried?" "How long has this been waiting?" "When did the previous next-action complete?" — these are first-class queries the system needs to answer to be the guardrail you want. They are trivial against (b), painful against (a).

The cost: more schema downstream, and a write per next-action transition. Both seem acceptable for the foundational benefit.

This also gives a clean home for the Q3 distinction:
- A NextAction in `waiting` state has 1+ **Pending Resolutions** attached (Type A).
- A NextAction in `active` state may have 0+ **Context Requirements** attached (Type B).
- A Task itself has no blockers — only its current NextAction does.

Do you accept NextAction as a domain entity?

---

## user

This also becomes a core insight for improving the clarify cycle as part of daily-ritual-redesign or #184

---

## assistant

Yes — the NextAction-entity model gives clarify a structured handle. Each clarify cycle = "the previous NextAction is done; what's the new one?" Provenance (#184) operates on Task identity for split/merge and on NextAction identity for clarification trail. Two distinct provenance flavors fall out of one model.

---

## Question 6: One current NextAction per Task at a time, or can a Task have multiple parallel NextActions?

This is the cardinality invariant on the Task ↔ NextAction relationship.

**(a) Strictly one current NextAction per Task at any moment.** Past NextActions exist as history (done or abandoned); exactly one is current. To move forward you complete it; to wait you transition it to waiting state; to revise it you abandon it and create a new one.

**(b) Multiple current NextActions allowed.** A Task can have several active or waiting NextActions in parallel ("research flights" AND "research hotels" for "plan vacation").

---

**My recommendation: (a) — strictly one current NextAction.**

Reasoning:

1. **GTD orthodoxy.** GTD's core defines next action as "the very next physical, visible action." Singular by definition. When a user feels they have multiple parallel next-actions, GTD says the project is too coarse — split it.

2. **The tenet wants this.** "Outcome-over-action" means the system knows what outcome you're trying to achieve and what the *single* lever is right now. Multiple parallel NextActions let the user dodge the clarification work — "I'm doing both, sort of" — which is exactly the cognitive overhead the tenet says we should be guarding against.

3. **Cleaner state.** "Is this Task actionable right now?" reduces to "is its current NextAction in `active` state with all Context Requirements satisfied?" One thing to evaluate, not a fold over a list.

4. **The "wait for Alice AND Nov 30" case is not a counter-example.** It's one NextAction (`wait`) with two Pending Resolutions ANDed — not two NextActions. The action you're taking is the same: waiting. What you're waiting *for* is decomposable; the action itself isn't.

5. **The "research flights AND research hotels" case is the genuine counter.** Under (a) the answer is: split into two Tasks (each with its own outcome — "flights booked," "hotels booked"), parented to or sequenced after a higher Task ("vacation planned"). This bumps into the deferred Project/TaskBlocker question for the *parent linkage*, but the children are clean: one outcome, one current NextAction each. We absorb the cost in v1 by relying on tags/notes for parent-linkage and revisiting under Project later.

The cost of (a): users with sprawling multi-thread tasks are forced to split. That's friction. But friction *toward outcome-clarity* is exactly the guardrail the tenet endorses — the system pushing the user to think clearly about outcomes rather than letting them stay vague.

Do you accept the singular-NextAction invariant?

---

## user

Singular next action is right. Having parallel actions will leave the user with choice paralesis(first person experience). Forcing the user to clarify and choose is a couple of minute effort for clutterfree mind. While book hotels and flights is a genuine case of parallelism, the outcome is still plan vacation. It can have multiple actions but only one true "next" action. It is worth forcing the user to choose whether they want to do flights or hotels first. Once the task is started, the user may come across dependencies that require hotels first, but that's when the user would stop work and re-order the actions to come up with a new next-action.

---

## assistant

Important nuance from your answer: "It can have multiple actions but only one true next action" + "re-order the actions" — both suggest a Task has a *list* of actions, not just a singleton + history. That's a fork worth pinning down.

---

## Question 7: Does a Task have *planned future* NextActions, or only *current + past*?

**(i) Strict — only current + history.** A Task has at most one current NextAction, plus a record of completed/abandoned ones. There is no stored "upcoming list." When the current NextAction finishes, the system prompts the user to clarify the new one — just-in-time. The user's sense of "next I'll do hotels" lives in their head (or in Task notes), not as a stored entity. "Re-ordering" means re-deciding at clarification time which action comes next.

**(ii) Plan-aware — current + past + planned.** A Task has an ordered list of NextActions, some done, one current, some planned. The current = the first non-done in the list. Adding a planned action, deleting one, or re-ordering them is a first-class operation. When the current finishes, the next planned slides into "current" automatically (or the system asks the user to confirm).

---

**My recommendation: (i) — strict.**

Reasoning, weighed against your last message:

1. **GTD warns specifically against pre-planning multi-step actions.** The "next action" in GTD is just-in-time clarification — Allen explicitly calls out that pre-planning future actions is busywork that the world will invalidate. By the time you finish flights, what you learned changes what hotels-research even means. Pre-stored "hotels" can become stale before you reach it.

2. **The tenet endorses friction-toward-clarification.** You said "forcing the user to clarify and choose is a couple of minute effort for clutter-free mind." That same logic applies to *each* transition: clarify the new NextAction *now*, not when the Task was first created. Pre-planned NextActions let the user dodge that re-clarification.

3. **"Re-ordering" reads cleanly as re-clarifying.** When you said "the user would stop work and re-order the actions to come up with a new next-action," I read that as: the user *had been thinking* about flights as next, hits the dependency, and re-clarifies — the new current NextAction is hotels. The "actions" being reordered are *mental* actions in the user's plan. They don't have to be stored entities for that to work.

4. **The Task notes already exist as a place to jot ideas.** "Things I think I'll need to do: flights, hotels, packing, transit-from-airport" can live in the Task description as informal text. That's where GTD's "project plan" lives — informal, freeform. Promoting these to first-class NextAction entities turns informal planning into a structured commitment.

5. **Avoids a state-explosion question.** Under (ii) we have to define: when can a planned NextAction have its own blockers? Can a planned NextAction be edited freely, or only when it becomes current? What happens to a planned NextAction's blockers when it's reordered? Each is a sub-modelling exercise. Under (i) those questions don't exist.

The cost of (i): the user can't "stash" a thought like "after this, hotels" in a structured slot — they have to put it in notes or trust they'll remember at re-clarification. For some users this feels like losing a tool. But it's the same tradeoff as GTD-on-paper, which works fine.

Counter-pull I want to make sure I'm hearing: did you mean (ii) when you said "re-order the actions," or did you mean (i) in metaphorical terms?

---

## user

(i) however, I don't want to leave thoughts in user's head, that goes entirely against the GTD philosophy. We do want to provide a structure for jotting down a list of next actions: a bullet list, a check-list, free form what ever. However, it's important to not over engineer it. No strict next action waterfall. No pre-plumbed dependency tracking. The task notes is a good place to store these next actions. At best it becomes a heading/sub-section that allows AI (post the milestone) to get a better context, along with user.

---

## assistant

Saving this corollary — it's a real design constraint going forward.

---

## Question 8: When a NextAction's Pending Resolutions all clear, does the same NextAction become active, or does a new NextAction begin?

This is about the lifecycle of NextAction across a wait.

**(a) Same NextAction transitions waiting → active.** A NextAction is a single thing with a description ("review Trixy's document") and a state. It starts in waiting (because resolutions exist), then flips to active when resolutions clear, then to done when the user marks it complete.

- One NextAction per "thing the user wants to accomplish toward the outcome."
- Wait is a *state* of the action, not the action itself.
- "Review Trixy's document" exists from the moment Trixy was sent the doc — it's just gated.

**(b) Each phase is its own NextAction. Wait is itself a NextAction; clearing a wait completes that NextAction and triggers re-clarification.**

- Phase 1: NextAction "send doc to Trixy" (active → done)
- Phase 2: NextAction "wait for Trixy" (waiting → done when resolution clears)
- Phase 3: NextAction "review Trixy's document" (active → done) — created at the clarify step after phase 2
- Phase 4: NextAction "send revisions" (active → done)
- Phase 5: NextAction "wait for revised doc" (waiting → done) — etc.

Each act, including each wait, has its own NextAction. The wait-action completes when the wait ends; the user is then prompted to clarify the new NextAction.

---

**My recommendation: (b) — wait is its own NextAction; clearing it triggers re-clarification.**

Reasoning, tied to tenet:

1. **The tenet wants re-clarification at every transition.** Under (a), the act of reviewing the document was implicitly committed-to at the moment the doc was sent — the user pre-decided "next I'll review" before they'd seen what Trixy returns. That's the same kind of premature commitment as (ii) in Q7. Under (b), the user clarifies *after* seeing what comes back: maybe Trixy returned something that needs a different action than "review" (e.g., "escalate to Trixy's manager because the reply was nonsense"). Re-clarification at the moment of resolution is more honest.

2. **The wait IS the user's commitment.** "I'm waiting on Trixy" is a thing the user is doing — it's tracked, surveilled, has its own lifetime, and may itself trigger follow-ups. Modelling it as a NextAction (with its own done-state) makes it visible as an act in the Task's history. Under (a), the wait is invisible — no record that "Trixy was waited on for 2 weeks before flipping to active."

3. **AI follow-up needs this.** "Auto-follow-up if waiting on Person too long" is a behavior on a *waiting NextAction* with its own lifetime. Under (a), the same waiting state has both "waiting on Trixy this round" and "waiting on Trixy a previous round" smeared together — no per-wait timer. Under (b), each round of waiting is its own NextAction with its own age.

4. **Symmetric treatment of "wait" and "do."** Both are acts the user takes (passively or actively) toward the outcome. They share the lifecycle (created → done) and the entity. The only difference is what causes the transition to done — user action vs. resolution clear.

Cost of (b): more NextActions in history; the user has to re-clarify more often. The re-clarification cost is exactly the friction we said is good ("2-minute effort for clutter-free mind"). The history-volume cost is small per-Task and high-value for AI/audit.

Counter-pull I want to test: under (b), what's the **description** of a wait NextAction? Is it auto-generated ("wait for Trixy") or user-typed? My instinct: auto-generated from the PendingResolution(s) it's waiting on, editable by the user if they want to add nuance. Worth confirming separately, but the lifecycle question is the higher-order one.

Do you accept (b) — wait is its own NextAction?

---

## user

I would question the entire premise of next action waiting. Next action is the one thing user can do to take the thing forward. waiting is not something the user can do. And review doesn't exist until the user receives a 2 page doc(instead of 1 para summary). So neither is the right choice. The insight here is the same as previous question. Next-action, similar to future actions or the past actions, is a light weight abstraction to focus the user. It's not something to be tracked. The outcome is tracked. The outcome is blocked on trixy. After waiting a couple of days "Follow up with trixy" is the next action that came out of that. After trixy sends the document, "Review" becomes the next action. If trixy sent a one line summary, "Decide" becomes the next action. If trixy doesn't answer the phone for a follow up, escalate to manager becomes the next-task. next task is a very lite-weight abstraction that is performed in one focus session to move outcome forward. When the next-action is done, we use the context to re-clarify whether the outcome is achieved or there is a new next task or a new blocker. Next-action is created and done or abandoned. nothing else.

---

## assistant

Major correction landing. Let me restate the revised model in your terms before asking the next question:

---

**Revised model:**

- **Task** = persistent outcome. The thing tracked.
- **Blockers** (both Pending Resolutions and Context Requirements) attach to **Task**. They describe what's outside the user's hands — state of the world relevant to the outcome.
- **NextAction** = a lightweight abstraction representing "the one thing the user can do in one focus session to move the outcome forward." A Task has 0 or 1 current NextAction. Created → done or abandoned. **No waiting state.** Nothing else.
- **Re-clarification** happens when a NextAction is done/abandoned. The system uses the new context (blocker state, what happened, time elapsed) to ask: outcome achieved? new blocker? new NextAction? nothing right now?
- **NextActions and blockers can coexist.** A Task blocked on Trixy can still have a NextAction "follow up with Trixy" — the act doesn't violate the blocker; it's the user's response to the blocker.
- A Task can also have **no current NextAction** for a stretch of time — user has consciously decided to wait, no action chosen yet.

Insight: blockers describe *outside-the-user* state; NextActions are *the user's hands acting*. They are independent dimensions, not gates on each other.

---

This invalidates the issue body's claim that `actionable = … ∧ blockers.all(satisfied)`. Blockers don't strictly gate actionability. Did I parse you right?

If yes, then:

## Question 9: When a NextAction completes, what's its relationship to the blockers on the Task?

Three patterns I see in your Trixy example:

**(α) NextAction *attempts to clear* a blocker, but doesn't necessarily succeed.**
"Follow up with Trixy" → done → blocker "waiting on Trixy" might still be active (Trixy didn't reply yet). The NextAction completing is a separate event from the blocker clearing.

**(β) NextAction *resolves on receiving information from outside.***
Trixy sends the document → blocker "waiting on Trixy" is cleared by *receiving the doc*, not by any NextAction. The clearing is an external event the user records.

**(γ) NextAction *replaces the blocker structure entirely.***
Trixy responds with a 1-line summary instead of the doc → user re-clarifies; the blocker is no longer "waiting on Trixy" (that's resolved); the new NextAction is "decide" with no remaining Trixy-blocker. The blocker structure mutates as part of re-clarification.

All three appeared in your example. The model needs to support them all.

**My recommendation: model them as separate orthogonal mechanisms:**

1. **A Pending Resolution clears via its own clearing event** (user marks "Trixy replied" or system detects time has passed). This is independent of any NextAction.
2. **A NextAction completes via its own done/abandoned transition.** Independent of blockers.
3. **Re-clarification ties them together.** When *either* a blocker clears *or* a NextAction completes, the system prompts the user to re-clarify the Task: any new state, any new NextAction, anything done?

Implication: a NextAction does not "carry" a blocker-clearing semantic. The user separately marks "Trixy replied" (clearing the Pending Resolution) and separately marks "follow up call done" (completing the NextAction). The system just notices either-or-both happened and triggers re-clarification.

The cost: two micro-actions where one might suffice ("I followed up AND that's how I learned Trixy already replied"). Defensible: re-clarification is *exactly* the moment to capture both pieces of state cleanly, and the tenet wants that friction.

Did I parse the revised model right, and do you accept the orthogonal-mechanisms framing for Q9?

---

## user

Before I answer, can you think of any analogous examples for other types of blockers other than the waiting-for we explored here?

---

## assistant

Let me walk through each.

---

**TimeBlocker (specific): "Renew lease after Nov 30"**

Blocker: "Nov 30 hasn't arrived."

- (β) holds cleanly: time advancing clears it. Pure passive external event.
- (γ) holds: re-clarify to renew earlier — mutates the blocker out.
- (α) degenerates: user *cannot* "follow up with Nov 30." The closest action — "negotiate the date with the landlord" — isn't clearing the blocker; it's mutating it (γ) by changing what we're waiting for.
- Concurrent NextActions: yes. "Research market rates," "gather lease documents," "draft renewal letter" all move the outcome forward alongside the wait. None clear the blocker.

**TaskBlocker: "Set up new desk, after the desk arrives"** (delivery being its own Task)

Blocker: Task A (desk arrival) not done.

- (β) holds: Task A's `done_at` being set clears Task B's blocker. From B's perspective, this is "external" even though the same user owns A — they're different outcomes.
- (γ) holds: re-clarify B to drop the dependency (assemble the old desk, repurpose the room).
- (α) doesn't apply on Task B: NextActions that probe "did the desk arrive yet?" — like "call delivery for status" — actually belong on Task A, not B. From B's perspective, no NextAction probes its own blocker.
- Concurrent NextActions on B: yes. "Clear space in office," "order assembly tools," "find instruction PDF."

**TimeBlocker (recurring): "Open mic Tuesdays and Thursdays"**

This is the Type B (Context Requirement) shape we identified in Q3.

- (β) doesn't apply: nothing *clears*. The window arrives, the window passes. The user-relevant state oscillates.
- (γ) holds: re-clarify to drop the constraint or change venue.
- (α) doesn't apply: user can't probe Tuesday into existence.
- Concurrent NextActions: the constraint *gates* NextAction visibility — "do open mic" only surfaces Tue/Thu. Outside the window, no NextAction at all. This is a different shape from PersonBlocker, where coexistence was the whole point.

**LocationBlocker: "Fix garage door at home"**

Also Type B.

- (β) doesn't apply in the clearing sense: location changes are reversible. User goes home → satisfied; user leaves → not. No durable clearing event.
- (γ) holds: re-clarify to drop the constraint or move the work.
- (α) sort of: "go home" satisfies the requirement, but going home is rarely a NextAction *on this Task* — usually incidental. When it is intentional, it's still mutation-ish, not clearing.
- Concurrent NextActions: telling. "Fix garage door" needs home. "Buy replacement spring" doesn't. Same Task, different NextActions, different context. So the location requirement isn't on the *Task*; it's on *certain NextActions*.

---

## Pattern that emerges

Two distinct shapes — and they map exactly to your Q3 split:

| | **Pending Resolutions** (Person, Time-specific, Task) | **Context Requirements** (Time-recurring, Location) |
|---|---|---|
| Attach to | **Task** ("the outcome is blocked on Trixy") | **NextAction** ("this *act* needs home") |
| Clearing event | Yes (β) — single, durable | No — predicate over world state |
| Mutable via re-clarification | Yes (γ) | Yes (γ) |
| Coexist with NextActions | Yes — actions act *alongside* the wait | No — they *gate* which NextActions are even valid |
| User-probable | Sometimes (α — PersonBlocker most clearly) | Effectively no |

So the revised framing — "blockers attach to Task; NextActions are independent agency" — holds **for Pending Resolutions**. It strains for Context Requirements: those don't really live on the Task because the same Task can have NextActions with different context needs ("fix the door" vs. "buy the spring"). They live on the NextAction.

This actually gives the model a cleaner split than I had before:

- **Task** has 0+ Pending Resolutions + 0 or 1 current NextAction.
- **NextAction** has 0+ Context Requirements.
- Pending Resolutions clear via external events; coexist with NextActions; describe outside-the-user state of the outcome.
- Context Requirements gate which NextActions are even surfaceable; describe constraints on acting.

The (α / β / γ) framing was Pending-Resolution-specific. (β) and (γ) generalize as a pattern only there. Context Requirements have a different mechanism — they don't "clear," they're just satisfied or not at any given moment.

Now I'll wait for your reaction before posing Q9.

---

## user

You are right, What we called blockers are actually two different things: blockers and contexts. You can have both simultaneously: Follow up with trixy(blocker) but she is only available 9-5(context).

---

## assistant

Yes — confirmed example. Saving the vocabulary.

Your example also implicitly answers Q9: NextAction "follow up" completing doesn't auto-clear the Blocker (Trixy may or may not have actually replied during the call). They're independent events; re-clarification ties them together. Locking that in.

---

## Question 10: What replaces "actionable" as a query?

The issue body claimed: `actionable = clarified ∧ ¬done ∧ intent=next ∧ blockers.all(satisfied)`. Under the revised model, the last clause is wrong — Blockers don't gate actionability. So we need a replacement.

The planning ritual asks several questions of a Task at different moments:
- "Is this Task in the Inbox or already clarified?"
- "Does this Task have a current NextAction?"
- "Can I do this NextAction *right now*, in this place, at this moment?"
- "What's stuck? Where am I waiting?"

Old "actionable" tried to roll these into one predicate. The cleaner model splits them.

**My recommendation: drop "actionable" as a single predicate. Replace with three independent dimensions:**

1. **`hasNextAction(task)`** — does the Task have a current NextAction (not done/abandoned)?
   - The clarify status: has the user thought about it enough to commit to a next move?
   - Independent of Blockers and Contexts.

2. **`isDoableNow(nextAction)`** — are all of this NextAction's Contexts satisfied right now?
   - The context check: am I in the right place / time to do this?
   - Only meaningful for NextActions that exist.
   - Empty Context list ⇒ trivially doable.

3. **`isBlocked(task)`** — does this Task have any unresolved Blockers?
   - The descriptive state: is this outcome waiting on something outside the user's hands?
   - Orthogonal to whether a NextAction exists. A Task can have a NextAction *and* be blocked (the "follow up" case). A Task can have no NextAction *and* be unblocked (just-clarified, action not yet defined). All four combinations are real states.

The four-quadrant matrix:

| | unblocked | blocked |
|---|---|---|
| **has NextAction** | classic "ready to act" | acting against / around the block (follow up, escalate, prep) |
| **no NextAction** | needs clarification *now* — outcome can move, just no action defined | passive wait — user has chosen no action, just monitoring |

Each cell has a different role in the planning ritual:
- Top-left: pick from these for "what to do today."
- Top-right: same — these are doable, just have a blocker context.
- Bottom-left: surface for clarify ritual — "decide what to do next."
- Bottom-right: surface in weekly review — "is the wait still acceptable, or time to escalate?"

The existing predicate "actionable" tried to be the top-row check but failed by gating on Blockers. The new top-row check is `hasNextAction(task) ∧ isDoableNow(currentNextAction(task))` — Blockers don't enter.

The "did I clarify it" check (predecessor of inbox-vs-next) is now subsumed: a clarified Task either has a current NextAction or has been deliberately marked "no action right now." An unclarified inbox item has neither.

Cost of dropping the single predicate: more code touchpoints have to ask the right specific question rather than reusing one boolean. That's correct — the previous boolean was conflating questions that should have been separate.

Do you accept the three-dimensions framing, or do you want a different split?

---

## user

this is good.

---

## assistant

Locked.

---

## Question 11: For each Blocker variant in v1, what does it carry, and how does it get cleared?

We have three v1 variants. Each is a different kind of "what's outside the user's hands." Modelling each as an isolated concept first, then we can compare.

### PersonBlocker

- **Carries:** identity of who we're waiting on, plus optional notes ("waiting for review on the doc I sent").
- **Cleared by:** user explicitly recording "the wait is over" (Trixy replied). The user is the only authority that knows.

Open sub-question: is "person" a string label or a first-class Person entity? My recommendation for v1: **string label.** Person-as-entity unlocks AI consolidation ("you have 3 things pending with Trixy") but introduces a whole new entity, sync rules, and identity-merge problems (typo variants of names). Deferring it costs us only a future migration; not deferring inflates v1 scope significantly.

### TimeBlocker (specific)

- **Carries:** a target instant ("not before Nov 30 09:00"), plus optional notes ("lease minimum-notice clause").
- **Cleared by:** the clock crossing the target instant. Passive — no user action needed. The system observes; the user might not even notice.

Open sub-question: time-zone semantics. "After Nov 30" — is that Nov 30 00:00 local-to-user, or local-to-the-task-context, or UTC? My recommendation: **stored as UTC instant; resolved to user's planning timezone for display/comparison.** Same convention the rest of the codebase uses (`day_boundary` memory).

### TaskBlocker

- **Carries:** a reference to the blocking Task's identity, plus optional notes ("we need this before assembly").
- **Cleared by:** the blocking Task's outcome being achieved (`done_at` set). Passive observation — the system detects when the other Task's `done_at` becomes non-null.

Open sub-questions:
- **Cycle prevention:** disallow at create-time (A blocks B; trying to add B-blocks-A is rejected). My recommendation: yes, enforce no-cycles invariant at the model level.
- **Self-blocker:** disallow A-blocks-A. Trivial, just enforce.
- **What if blocking Task is later abandoned?** My recommendation: blocker auto-clears (Task A no longer pending; whatever B was waiting on is moot). Note this in the Task A history so the user knows why B's blocker cleared.
- **What if blocking Task is later un-done (`done_at` cleared)?** My recommendation: blocker re-engages. The Task B blocker is *cleared iff Task A is currently done*, evaluated continuously, not "cleared once, stays cleared." This honors the world-state-tracking nature of the predicate.

### Across all three: shape of "cleared"

Two distinct mechanisms:
- **PersonBlocker:** "cleared" is a stored event (`cleared_at` set by user action). The Blocker carries it.
- **TimeBlocker, TaskBlocker:** "cleared" is a *computed predicate* over external state (`now >= target_time`, `blocking_task.done_at IS NOT NULL`). The Blocker doesn't store "cleared"; it stores the *reference data*, and clearing is derived.

My recommendation: **honor this distinction at the domain level.** Don't denormalize a `cleared_at` onto Time/Task Blockers — let it be derived. Otherwise we have to reconcile drift (target_time changes; blocking_task gets un-done; etc.).

---

Three questions for you to chew on, ideally one-at-a-time response if any need debate:

1. Person as v1 string label, defer Person-entity? (my reco: yes, defer)
2. Cycle prevention + auto-clear-on-abandon + re-engage-on-undone for TaskBlocker? (my reco: yes to all three)
3. Computed-vs-stored distinction for "cleared"? (my reco: honor the distinction; don't denormalize)

---

## user

1. We have a better mechanism: Tags. Person as a Tag{type: person}. Achieves the same goal of being simple, yet queriable ("what's my agenda for meeting with trixy?")

---

## assistant

Elegant. Confirmed — Tags already have type discriminator (`'context','project','area','label'`); adding `'person'` is a natural extension (expand CHECK constraint, no new entity). Saves a Person entity AND gives the cross-Task query for free ("show all my pending things tagged @trixy"). Saving this.

Now your call on the remaining two from Q11. Taking one at a time:

---

## Question 11.2: TaskBlocker semantics

Three sub-decisions, all my-recommendations are yes:

**(a) Cycle prevention** — "A blocks B" + "B blocks A" rejected at create-time. Detected by graph walk on the Tag-Block-Task graph. Domain invariant: no cycles.

**(b) Auto-clear when blocking Task is abandoned** — Task A is abandoned (intent=trash, or some "abandoned" state). Task B was blocked on A. The blocker on B auto-clears. Reason: "we're not pursuing A anymore" means "B is no longer waiting on A's outcome." A trace remains in B's history showing why the blocker cleared.

**(c) Re-engage when blocking Task is un-done** — Task A had `done_at` set, then user clears it (mistake, or outcome reverted). Task B's blocker on A re-engages. Reason: "cleared" is a *predicate* on A's current state, not a stored fact on B. If A is no longer done, B is no longer unblocked. This is the world-state-derived nature of computed Blockers.

Question: do you accept all three, or is one of them wrong?

---

## user

Before that, I would move Time blocker to context `now in (start_time..forever)`

---

## assistant

Sharp move. "After Nov 30" is `now ∈ [Nov 30, ∞)` — same predicate-shape as recurring time, just with one open-ended interval instead of repeating intervals. Both are Contexts. The two collapse into one concept (time-interval Context); recurring vs. open-ended is just a property of the interval set.

This is also more honest about the user's experience. "Renew lease after Nov 30" doesn't block the *outcome* — the user can prep, research, draft a letter while waiting. What's constrained is the *act of submitting the renewal*. Pre-conditions belong on actions, not on outcomes.

Worth noting the related distinction this exposes:
- **Deadline** ("by Nov 30") = property of the *outcome*. Stays on Task. Already exists today as `due_date`.
- **Pre-condition** ("after Nov 30") = property of an *action*. NextAction Context.
- These were silently conflated under the old TimeBlocker; the re-classification splits them cleanly.

---

This shifts v1 scope. Originally (Q2): v1 = TaskBlocker + PersonBlocker + TimeBlocker(specific), deferring all Contexts.

**With the re-classification, the question is: does v1 still cover the time case?**

Two options:

**(a) Pull time-Context into v1.** v1 Blockers = {PersonBlocker, TaskBlocker (plumbing)}; v1 Contexts = {TimeContext with single open-ended interval shape}. Recurring-time and Location stay deferred. The cost is that Context-as-a-concept ships in v1 (NextAction model has 0+ Contexts attached), but with one tightly-scoped variant. The benefit: "renew lease after Nov 30" works in v1 as a structured Context, not as freeform text.

**(b) Defer time-Context too. v1 = pure Blockers.** v1 Blockers = {PersonBlocker, TaskBlocker (plumbing)}. All Contexts (including time) deferred. The "after Nov 30" use case is handled by user typing it in Task notes / title — no structured Context. Context-as-a-concept doesn't ship until later.

**My recommendation: (a) pull time-Context into v1.**

Reasoning:
- The data shape is trivial — a single `start_time` (open-ended interval) on a NextAction Context. No RRULE-vs-enum sub-debate. The complex recurring-time and Location remain deferred.
- Without it, "after Nov 30" use cases become freeform notes — the user has to remember to clarify the right NextAction at the right time, with no system support. That's a real loss.
- It validates the Context concept in v1, which means #180 can integrate Contexts into the planning ritual without waiting for v2.
- Marginal scope creep: adds one entity (Context) and one variant. Same plumbing pattern as Blocker.

Counter-pull: (b) is faster. But I think the marginal cost is genuinely small.

Which do you want — (a) or (b)?

---

## user

choosing a would mean creating the plumbing for contexts not only in domain and data modelling but also in UI/UX. And then you don't get returns on it until v2. I would do (b) so that v1 can ship out.

---

## assistant

Updating memory to reflect the re-classification and v1 scope.

Memory updated. v1 = Blockers only (PersonBlocker active, TaskBlocker plumbing only). All Contexts deferred. Time pre-conditions handled as freeform notes in v1.

---

Returning to **Q11.2 — TaskBlocker semantics**. Three sub-decisions, my-recommendations all yes:

**(a) Cycle prevention.** Reject "A blocks B" when "B blocks A" already exists. Detected by graph walk on the Tag-Block-Task graph at create-time. No-cycles is a domain invariant.

**(b) Auto-clear when blocking Task is abandoned.** Task A → abandoned (intent=trash). Task B was blocked on A. Blocker on B auto-clears. Reasoning: "we're not pursuing A" means "B is no longer waiting on A's outcome." Trace remains in B's history showing why the blocker cleared.

**(c) Re-engage when blocking Task is un-done.** Task A had `done_at` set, then user clears it (mistake / outcome reverted). Task B's blocker on A re-engages. Reasoning: TaskBlocker "cleared" is a *predicate* over A's current state, not a stored fact on B. If A is no longer done, B is no longer unblocked.

Accept all three, or is one wrong?

---

## user

a) yes.
b) Time to reclarify. No reason to assume it unblocks. It might mean B is also destined for trash.
c) yes. So task blocker also behaves like a context it's blocked? is evaled against the blockers done state instead of being a stored state that is flipped.

---

## assistant

Strong observation. You're right — TaskBlocker breaks the original Blocker/Context split if we drew it on clearing mechanism. Let me restate cleanly:

**The Blocker/Context distinction is about attachment + scope, not about how clearing works.**

| | **Blockers** | **Contexts** |
|---|---|---|
| Attaches to | Task (the outcome) | NextAction (the act) |
| Describes | Outcome-level outside-the-user state | Action-level constraint on doing |
| Coexists with NextActions | Yes (act alongside the wait) | No — gates which actions surface |
| **Clearing mechanism** | **Per-variant** | All predicate |

And within Blockers, the clearing mechanism varies:

- **PersonBlocker:** event-recorded. User explicitly marks "Trixy replied"; `cleared_at` is stored. The user is the only authority who can know.
- **TaskBlocker:** predicate-evaluated. `cleared = blocking_task.done_at IS NOT NULL`. No stored `cleared_at`. Re-engages on un-done. Same "world-state derived" mechanism Contexts will eventually use.

So Q11.3 (computed-vs-stored) is implicitly answered: per-variant. Updating memory.

Your (b) introduced an important new mechanism: upstream events (blocking Task abandoned/done/un-done) cascade to dependents and require re-clarification. Let me pin down how the model represents that.

---

## Question 12: How does the system know which Tasks need re-clarification?

After the decisions so far, several events should bring a Task back to the user's attention:

1. Current NextAction transitioned to done or abandoned — Task has no current NextAction.
2. PersonBlocker cleared (Trixy replied) — situation changed; "now what?"
3. Blocking Task done / un-done / abandoned — TaskBlocker state on a dependent flipped.
4. New Blocker added — fresh constraint.

These all warrant a re-clarification prompt to the user. The question is whether the model represents this **explicitly** or **derives it**.

**(a) Derived.** Each Task carries a `last_clarified_at` instant, set whenever the user clarifies (creates a NextAction, modifies a blocker, marks done/abandoned, or explicitly says "I've reviewed, nothing to change"). "Needs re-clarification" is computed at query time: any state change since `last_clarified_at`, OR (Task is active AND current NextAction is null). One timestamp, many derived predicates.

**(b) Explicit flag.** Task carries a `needs_review: bool`. Set by event handlers when upstream changes happen. Cleared by user review. Two pieces of state instead of one.

---

**My recommendation: (a) — `last_clarified_at` derived.**

Reasoning:

1. **Single source of truth.** Both a flag and a timestamp could drift apart from actual events. A timestamp encodes "I've engaged with this Task as of T"; everything else is derivable from comparing T against authoritative state.

2. **Multiple derived predicates fall out for free.** "Tasks last-clarified > 30 days" (weekly review surface). "Tasks where any blocker changed since last clarification" (re-clarify queue). "Tasks where a TaskBlocker target's `done_at` flipped after last_clarified_at" (downstream cascade). All same underlying field.

3. **AI-ready.** Phase 4 features want "this Task hasn't been clarified in N days" or "this Task's blocker changed but the user hasn't reviewed." Both fall out of the timestamp.

4. **Honors the tenet.** Explicit `needs_review` flag invites the system to be the arbiter ("I decide when you review"). Derived from `last_clarified_at` invites the user to be the arbiter ("I review when I review; the system shows me what's changed since then"). The latter is more aligned with "system supercharges the user, doesn't replace."

5. **Cheap.** One nullable timestamp on Task. Updated on user actions (no event handlers needed). All cascade detection is read-side.

The cost: queries are slightly more complex (compare timestamp against multiple state-change sources). Acceptable.

Implication for cascades: when Task A is abandoned, the system doesn't *push* a flag to dependent Bs. Instead, the next time the planning ritual runs (or the user opens B), the query finds that "blocking Task A's intent changed after B's `last_clarified_at`" and surfaces B for re-clarification. Pull, not push.

This also resolves a subtle question: what happens if the user *deliberately* doesn't re-clarify after upstream changes? Under (a), the Task just keeps showing up in the re-clarify queue until the user engages. Under (b), the flag sits set indefinitely. Same effect, but (a) is honest about why.

Do you accept the `last_clarified_at`-derived approach?

---

## user

Abandon is also contextual. During a focus session, the user may decide to "abandon" the task for today. or the user can decide to trash it forever. in the first case, the blocker is still active. The user just needs more time. The latter means consequences.

This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.

Summary:
1. Primary Request and Intent:
   The user (project manager of TMaYaD/Jeeves — a Flutter+FastAPI GTD app with PowerSync+Drift sync) engaged in a multi-stage workflow:
   - Initial triage of 5 delegation candidates with Trixy planning bot (#51, #84, #107, #184, #103) — all turned out to be UI/UX-blocked on the user
   - Backlog sift for UX-free engineering tasks — only #228 survived, already in flight
   - Decision to tackle #180 (daily planning ritual redesign) and #181 (polymorphic blockers domain modelling), with #181 plumbing first and #180 redesigning UX over it later
   - User initiated relentless interview-style domain modelling on #181 with explicit instructions: "Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer. Ask the questions one at a time. If a question can be answered by exploring the codebase, explore the codebase instead."
   - Multiple times user corrected me when I drifted into implementation/schema/UX details: "Don't jump into implementation detail with tables, schema design and SQL queries yet" and "Keep the exploration focused on domain modelling."

2. Key Technical Concepts:
   - GTD (Getting Things Done) methodology — outcomes vs actions, projects, next actions, contexts, waiting-for
   - Polymorphic blocker/context modelling
   - Flutter + Dart + Riverpod, Drift (local SQLite) + PowerSync sync to Postgres
   - FastAPI + SQLAlchemy + Alembic migrations
   - Tag system with type discriminator (existing)
   - Reminder model with single-table-with-discriminator precedent
   - Domain modelling vs implementation/schema design (user enforced separation)
   - Outcome-over-action design tenet
   - Predicate-shaped vs event-shaped state
   - Last-clarified-at timestamp pattern

3. Files and Code Sections:

   - **`/Users/phoenix/.claude/projects/-Users-phoenix-Documents-tmayad-Jeeves/memory/feedback_outcome_over_action_tenet.md`** (CREATED)
     - Core design tenet: Task = persistent outcome; next-action is the moving part. Product guards user toward outcome-thinking. AI features (Phase 4) amplify this.
     - "How to apply" rules including: don't propose models with persistent next-action as the tracked thing; "Done" means outcome achieved, not next-action completed.

   - **`/Users/phoenix/.claude/projects/-Users-phoenix-Documents-tmayad-Jeeves/memory/feedback_no_planned_action_entities.md`** (CREATED)
     - Future actions live in freeform Task notes, not as structured entities. No `plannedNextActions[]`, no dependency graphs, no auto-advance through stored lists.

   - **`/Users/phoenix/.claude/projects/-Users-phoenix-Documents-tmayad-Jeeves/memory/project_blockers_vs_contexts.md`** (CREATED, MODIFIED 4×)
     - Final state captures: Blockers attach to Task (PersonBlocker event-cleared, TaskBlocker predicate-evaluated, both v1); Contexts attach to NextAction (predicates, all deferred from v1); deadline (`due_date`) vs pre-condition split; TaskBlocker cascade rules (cycle prevention; abandon triggers re-clarification, NOT auto-clear; un-done re-engages).

   - **`/Users/phoenix/.claude/projects/-Users-phoenix-Documents-tmayad-Jeeves/memory/project_people_are_tags.md`** (CREATED)
     - PersonBlocker references `Tag(type='person')`. Reuses existing Tag infrastructure. No new Person entity. Cross-Task queries fall out for free.

   - **`/Users/phoenix/.claude/projects/-Users-phoenix-Documents-tmayad-Jeeves/memory/MEMORY.md`** (UPDATED multiple times)
     - Index updated with all new memories above.

   - **`/Users/phoenix/Documents/tmayad/Jeeves/backend/app/todos/models.py`** (READ)
     - Verified Tag model with `CheckConstraint("type IN ('context','project','area','label')", name="ck_tags_type")` — adding 'person' is a natural extension
     - Verified Reminder model uses `type: Mapped[str]` discriminator (`"time" | "location"`) as precedent for single-table-with-discriminator
     - Verified current Todo model: no `state` column (dropped in 0020), has `clarified`, `intent`, `waiting_for`, `due_date`, `location_id`. No `scheduled_at` on Todo.

   - **GitHub issues read**: #180 (3 daily-planning gaps for redesign) and #181 (polymorphic blockers epic).

4. Errors and fixes:
   - **Drifted into schema/SQL design (Question 3)**: User corrected: "Don't jump into implementation detail with tables, schema design and SQL queries yet. If we get the domain modelling right, good schema and data shapes will follow." Re-posed in pure domain terms.
   - **Drifted into UX implications (Question 3 retry)**: User corrected: "Keep the exploration focused on domain modelling." Re-posed even more tightly.
   - **Wrong assumption that TaskBlocker had migration data**: I claimed `blocked_by_todo_id` existed; actually stripped in migration 0012 per `docs/REQUIREMENTS.md:27`. Corrected.
   - **Wrong assumption that scheduled_at was on Todo**: Actually only on Reminder model. `scheduled` state was collapsed in 0011 preserving `due_date`. Corrected.
   - **Q5/Q8 NextAction-with-waiting-state framing**: User major correction: "I would question the entire premise of next action waiting. Next action is the one thing user can do... waiting is not something the user can do." NextAction has no waiting state. Created → done or abandoned. Restated entire revised model.
   - **TimeBlocker(specific) classified as Blocker**: User reclassified to Context: `now in (start_time..forever)` — predicate-shaped. Updated memory.
   - **Q11.2(b) auto-clear-on-abandon**: User rejected: "Time to reclarify. No reason to assume it unblocks. It might mean B is also destined for trash." Replaced with re-clarification cascade.

5. Problem Solving:
   Built up shared domain model for #181 through 12 questions:
   - Q1: #181 plumbing under #180; do plumbing now, UX later
   - Q2: v1 = PersonBlocker + TaskBlocker (plumbing only); defer TimeBlocker(recurring) + LocationBlocker; build variants one-at-a-time
   - Q3: Two concepts — Blockers (Task-attached, event-cleared, coexist) vs Contexts (NextAction-attached, predicate, gate visibility)
   - Q4: Task = persistent outcome (CORE TENET)
   - Q5: NextAction = domain entity
   - Q6: Singular current NextAction per Task (avoids choice paralysis)
   - Q7: No planned future NextActions; freeform Task notes only
   - Q8 (corrected): NextAction lifecycle is created → done/abandoned. No waiting state.
   - Q9 (implicit): Blocker clearing and NextAction completion are independent
   - Q10: Drop "actionable" single-predicate; three independent dimensions (hasNextAction, isDoableNow, isBlocked)
   - Q11.1: PersonBlocker = Tag(type='person')
   - Q11.2: TaskBlocker — cycle prevention yes, abandon → re-clarify dependents (NOT auto-clear), un-done re-engages
   - Q11.3 (implicit): cleared semantics is per-variant (PersonBlocker stored, TaskBlocker computed)
   - Time pre-condition reclassified to Context; deadline vs pre-condition split; v1 defers all Contexts
   - Q12 (in flight): proposed `last_clarified_at` derived approach

6. All user messages:
   - "180 with increased scope of integrating the UI/UX surface of 181 is the right call..."
   - "Defer task blocker. It's UX will be limited to showing up in daily planning ritual when there are no blockers and finding a good UI to show pending blockers in the detail page..."
   - "Don't jump into implementation detail with tables, schema design and SQL queries yet..."
   - "Keep the exploration focused on domain modelling."
   - "I agree. One is a 'context' of actionability and another is a 'blocker'. What's worth exploring further is how we should handle something like the following use case: 'Waiting for trixy' -> 'Trixy replied with document' becomes 'review trixy's document' on my plate..."
   - "Yes, But not just because it pushes project downstream. The key is the core GTD insight: the only thing worth tracking persistently is the outcome; the next action is whatever moves the outcome forward right now. We need to respect and make it a core tenet of our design language..."
   - "This also becomes a core insight for improving the clarify cycle as part of daily-ritual-redesign or #184"
   - "Singular next action is right. Having parallel actions will leave the user with choice paralesis(first person experience). Forcing the user to clarify and choose is a couple of minute effort for clutterfree mind..."
   - "(i) however, I don't want to leave thoughts in user's head, that goes entirely against the GTD philosophy. We do want to provide a structure for jotting down a list of next actions: a bullet list, a check-list, free form what ever. However, it's important to not over engineer it. No strict next action waterfall. No pre-plumbed dependency tracking. The task notes is a good place to store these next actions..."
   - "I would question the entire premise of next action waiting. Next action is the one thing user can do to take the thing forward. waiting is not something the user can do..."
   - "Before I answer, can you think of any analogous examples for other types of blockers other than the waiting-for we explored here?"
   - "You are right, What we called blockers are actually two different things: blockers and contexts. You can have both simultaneously: Follow up with trixy(blocker) but she is only available 9-5(context)."
   - "this is good."
   - "1. We have a better mechanism: Tags. Person as a Tag{type: person}. Achieves the same goal of being simple, yet queriable ('what's my agenda for meeting with trixy?')"
   - "Before that, I would move Time blocker to context `now in (start_time..forever)`"
   - "choosing a would mean creating the plumbing for contexts not only in domain and data modelling but also in UI/UX. And then you don't get returns on it until v2. I would do (b) so that v1 can ship out."
   - "a) yes. b) Time to reclarify. No reason to assume it unblocks. It might mean B is also destined for trash. c) yes. So task blocker also behaves like a context it's blocked? is evaled against the blockers done state instead of being a stored state that is flipped."
   - "Abandon is also contextual. During a focus session, the user may decide to 'abandon' the task for today. or the user can decide to trash it forever. in the first case, the blocker is still active. The user just needs more time. The latter means consequences."

7. Pending Tasks:
   - Continue domain-modelling Q&A on #181, one question at a time
   - User just introduced new insight requiring incorporation: "abandon" is contextual — daily abandon (rollover, blocker still active) vs forever abandon (trash, cascading consequences). This applies to BOTH NextActions AND Tasks.
   - Eventually: ratify the domain model and translate into engineering plan for #181 v1 plumbing
   - Then: #180 daily ritual redesign integrating the blocker UX surface

8. Current Work:
   Just before the summary request, I had asked Question 12: "How does the system know which Tasks need re-clarification?" Recommended option (a) — Task carries `last_clarified_at` timestamp, derive "needs re-clarification" from comparing it to authoritative state changes (vs option b explicit `needs_review` boolean). Reasoning included: single source of truth, multiple derived predicates fall out for free, AI-ready for Phase 4 features, honors the outcome-over-action tenet, cheap (one nullable timestamp).

   User's response introduced a NEW insight that doesn't directly answer Q12: "Abandon is also contextual. During a focus session, the user may decide to 'abandon' the task for today. or the user can decide to trash it forever. in the first case, the blocker is still active. The user just needs more time. The latter means consequences."

   This is a domain-level distinction between two abandonment semantics:
   - **Daily abandon (rollover/defer)**: NextAction or Task isn't done today. User just needs more time. Blocker still active. No cascading consequences.
   - **Forever abandon (trash)**: Outcome no longer pursued. Has consequences — cascades to dependents (re-clarification of TaskBlocker dependents, per Q11.2.b).

   Two distinct lifecycle transitions that need distinct names and distinct mechanisms in the model. The previously established TaskBlocker cascade rule (abandon → re-clarify dependents) only fires for forever-abandon (trash), not for daily-abandon (rollover).

9. Optional Next Step:
   Acknowledge the user's contextual-abandon insight and pose a question that integrates it into the model before returning to Q12.

   Specifically, restate the model with the new distinction:
   - NextAction lifecycle: created → {done, daily-abandon (rollover), forever-abandon (give up on this approach)}
   - Task lifecycle: active → {done (outcome achieved), daily-abandon (rollover for today), trash (outcome forever abandoned)}
   - Cascades on TaskBlocker only trigger on TRASH of blocking Task, not on rollover.

   Then ask the user to confirm this two-flavor abandonment shape before posing Q12 (re-clarification mechanism with `last_clarified_at`).

   Direct quote of the most recent user message that drives the next step: "Abandon is also contextual. During a focus session, the user may decide to 'abandon' the task for today. or the user can decide to trash it forever. in the first case, the blocker is still active. The user just needs more time. The latter means consequences."

   This needs to be folded into the model before the re-clarification mechanism can be properly designed, since the cascade rule from Q11.2(b) depends on which kind of abandonment occurred.

If you need specific details from before compaction (like exact code snippets, error messages, or content you generated), read the full transcript at: /Users/phoenix/.claude/projects/-Users-phoenix-Documents-tmayad-Jeeves/30713c87-db56-43bf-983d-859a3e0b4d14.jsonl
Continue the conversation from where it left off without asking the user any further questions. Resume directly — do not acknowledge the summary, do not recap what was happening, do not preface with "I'll continue" or similar. Pick up the last task as if the break never happened.

---

## assistant

Folding in your contextual-abandon insight before Q12.

**Two flavors of abandonment** — distinct lifecycle transitions, distinct semantics:

**NextAction lifecycle**: `created → { done | rolled-over | abandoned }`
- **done**: this specific action accomplished. Triggers re-clarification ("what's the new next action?").
- **rolled-over** (daily abandon): "not today." Action persists; user just needs another bite. Blocker still active. Task unchanged. No cascade.
- **abandoned** (forever): "this approach is wrong" — but the *outcome* may still be pursued via a different next action. Triggers re-clarification of the Task. No cascade to other Tasks (because Task isn't trashed).

**Task lifecycle**: `active → { done | rolled-over | trashed }`
- **done**: outcome achieved.
- **rolled-over** (daily abandon): "not today." Outcome still wanted. Blockers still active. No cascade.
- **trashed** (forever abandon): outcome no longer pursued. **This is the only transition that cascades** — every Task with a TaskBlocker pointing at this one gets flagged for re-clarification (per Q11.2.b).

Key consequence: the cascade rule is gated on **trash**, not on any softer "I'm not doing this today" signal. Rollover is cheap and consequence-free; trash is the heavy-weight transition.

Implicit corollary: rollover is probably not even a stored state on the entity — it's just "didn't get done by end-of-planning-day." The day-boundary roll-over (planning time, not midnight, per memory) sweeps up unfinished NextActions and Tasks and re-presents them next planning session. The entity stays `active` / NextAction stays `created`. Only **done**, **abandoned** (NextAction), and **trashed** (Task) are recorded states.

Let me update the blockers/contexts memory to reflect this before moving on, then pose Q12.

Memory updated. Now back to Q12, with the cascade trigger sharpened to **trash** specifically.

---

**Question 12: How does the system know which Tasks need re-clarification?**

We've identified several events that should trigger re-clarification of a Task:

1. Current NextAction `done` → "what's the new next action?"
2. Current NextAction `abandoned` (this-approach-is-wrong) → "what's a different next action?"
3. PersonBlocker cleared → "wait is over, what's next?"
4. TaskBlocker un-done (blocking Task transitions back to incomplete) → "your blocker is back, reconsider"
5. **Blocking Task trashed** → "your dependency is dead, is this Task still viable?"

These are all moments where the Task's "what to do next" answer has gone stale. The system needs a way to surface "these Tasks need your attention to re-clarify."

**Recommended answer: option (a) — `last_clarified_at` timestamp on Task**

Each Task carries a `last_clarified_at` timestamp, set whenever the user clarifies (creates the Task, picks a new NextAction, confirms the current one is still right, etc.). "Needs re-clarification" is a **derived predicate**, not a stored boolean: `last_clarified_at < latest_relevant_state_change`.

Where "latest_relevant_state_change" is the max of:
- `current_next_action.done_at` / `current_next_action.abandoned_at`
- `person_blocker.cleared_at` for any cleared PersonBlocker on this Task
- `blocking_task.done_at` flipping to/from null (TaskBlocker re-engagement)
- `blocking_task.trashed_at` for any TaskBlocker pointing at a trashed Task

**Why (a) over (b) `needs_review` boolean**:
- **Single source of truth.** The blocker/action state changes are already authoritative. A boolean is a derived fact stored separately — it can drift (forgot to flip it, flipped wrongly, race conditions between sync clients).
- **Multiple derived predicates fall out for free.** "Stale Tasks" (clarified > 30 days ago, never), "freshly-blocked Tasks," "ready-for-planning Tasks" all use the same timestamp differently.
- **AI-ready (Phase 4).** "Tasks Jeeves should nudge about" needs the freshness signal anyway.
- **Cheap.** One nullable timestamp on Task. No cascade-write logic on every state change.
- **Honors outcome-over-action.** Re-clarification is a property of the Task (the persistent outcome), not derived from a flag tossed around between subordinate entities.

The trade-off: querying "needs re-clarification" requires joining through NextActions and Blockers. But Daily Planning already loads those for the planning view, so the join is paid once per session, not per Task.

Does (a) work for you, or do you want to push on (b) — explicit `needs_review` flag?

---

## user

a

---

## assistant

Good. (a) it is — `last_clarified_at` on Task, "needs re-clarification" is a derived predicate.

---

**Question 13: What stamps `last_clarified_at`?**

The predicate "needs re-clarification" only works if we know which user actions reset the clock. Some are obvious; others are judgment calls.

Candidate clarification events:
1. **Task creation** — initial clarify; the act of creating a Task with a NextAction *is* clarifying.
2. **NextAction created** (swap or first) — user picked what moves the outcome forward. Clearly clarifying.
3. **User explicitly confirms during planning** ("yes, this is still the right next action") without changing anything — a no-op edit that resets the clock.
4. **PersonBlocker added/removed** — the user actively re-shaped the Task's wait state. Probably clarifying.
5. **TaskBlocker added/removed** — same.
6. **Edit to Task title / outcome description** — user re-engaged with the outcome. Probably clarifying.
7. **Edit to freeform notes** — user touched the Task. Maybe noise, maybe clarifying.
8. **Tag change** (project/area/person assignment) — Probably clarifying.
9. **Due-date change** — Probably clarifying.

**Recommended answer: anything the user does to the Task's *clarification surface* stamps it. Anything else doesn't.**

Concrete cut:
- **Stamps**: create Task, create/swap NextAction, explicit "still good" confirmation, add/remove Blocker (any variant), edit title or outcome description, change due-date.
- **Doesn't stamp**: edit freeform notes, tag changes, viewing the Task, completing the current NextAction (that *un-stamps* — it's the event that makes re-clarification needed), the Task being affected by *external* events (blocking Task trashed, PersonBlocker auto-cleared).

The principle: `last_clarified_at` is updated by **the user actively answering "what does this outcome need from me?"** — not by passive edits, not by upstream events.

The crucial corner: **completing a NextAction does NOT stamp `last_clarified_at`.** That's the whole point — completion is what makes the Task stale. The very next user action — picking the new NextAction (or confirming the Task is done) — is what re-stamps it.

Symmetric corner: **rolling over a NextAction (daily-abandon) does NOT stamp.** The user said "not today," which is explicitly *not* re-clarification. The Task stays fresh-or-stale based on its prior state.

Does this cut make sense, or is there a clarification event you'd add/remove?

---

## user

It does. You are right in assuming done or abandon does not clarify the task. In fact that's probably the best time to trigger an inline clarification. Ex. The user is in a focus session and finishes the action and says done. That's when we should ask, did you achieve your desired outcome? if not, what's the next action.
tagging, or assigning contexts falls under organising rather than clarifying.

---

## assistant

Good cuts — let me lock these into memory before moving on.

Locked in. Inline-clarify-on-done is a flow detail for #180/#184 — I'll keep it in working notes for now rather than memory, since it's a UX expression of the principles already captured.

---

**Question 14: Is "Task with no current NextAction" a real state in the model?**

You just said the prime moment to ask "did you achieve your outcome? if not, what's next?" is when the user marks a NextAction done/abandoned in a focus session — i.e., **inline clarification**. Done atomically, the Task never visibly lacks a current NextAction; it transitions straight from one to the next (or to Task-done).

But not every NextAction completion happens in a focus session. The user might:
- Tap-to-complete from a list view and then close the app.
- Mark it done via a quick swipe and immediately switch contexts.
- Have the act-of-completing and act-of-clarifying separated by minutes, hours, or a day.

So in the model, "Task with current NextAction = none, awaiting re-clarification" is a real state — even if happy-path UX tries to make it transient.

**Recommended answer: yes, it's a real state. The model permits a Task to have zero current NextActions; the UX makes the happy-path inline-clarify atomic.**

Concretely:
- Task has `current_next_action_id` nullable, OR equivalently NextActions have `done_at`/`abandoned_at`/`is_current` such that "current" means "exists, neither done nor abandoned." (Schema choice deferred.)
- "Needs clarification" derived predicate fires whenever `last_clarified_at < latest_relevant_change`, which includes "the current NextAction transitioned to done/abandoned." This is the *same* predicate as before — Task-with-no-current-NextAction is just one shape of stale.
- Daily Planning surfaces these as "needs clarification" — same bucket as "blocker just cleared, please reconsider." From the user's perspective, both are "Jeeves needs your decision on what to do next."

**One UX implication worth noting** (not modelling, just connecting the dots): the inline-clarify focus-session flow you described is **the same prompt** as the daily-planning re-clarify queue. Same question — "did you achieve your outcome? if not, what's the next action?" — just at different moments. Phase 4 AI auto-clarify is the *third* surface of the same prompt.

Does this hold, or do you want NextActions structured such that there's *always* a current one (e.g., auto-create a placeholder "needs clarification" NextAction on completion)?

---

## user

You are right, the happy path may be choose next action immediately, but it's not optimal. Not just because something may interrupt(like closing app), but it may not be feasible UX wise as well. Imgaine having to play 20 questions for every item you pickup at grocery store. It would get annoying fast.

---

## assistant

Right — and that grocery-store framing matters for the model itself, not just UX cadence. Let me capture this before moving on.

Locked.

So the model has to permit **completion without re-clarification** as a first-class flow, not a degraded fallback. The "no current NextAction, awaiting re-clarification" state is the *normal* outcome for list-knockdown flows. Phase 4 AI gets a clear job: nudge the re-clarify queue at low-friction moments, not at point-of-completion.

---

**Question 15: What's the minimum to create a Task?**

By symmetry with the deferred-clarification principle: capture-now-clarify-later is the GTD inbox pattern. The user dumps a thought ("get document reviewed by Trixy") and clarifies whether/how to act on it later.

Three possible cuts:

**(a) Minimum = title only.** Task can exist with no current NextAction, no Blockers, nothing. Pure inbox capture. The Task is *implicitly* "needs clarification" until the user revisits it.

**(b) Minimum = title + initial NextAction.** Forces a moment of clarification at capture-time. Inbox-like dumping requires a placeholder NextAction.

**(c) Minimum = title only, but the model distinguishes "captured-not-yet-clarified" from "clarified-and-actionless."** Two different states with a `clarified_at` stamp (separate from `last_clarified_at`).

**Recommended answer: (a).**

Reasoning:
- The GTD discipline is "capture freely, process deliberately." Forcing a NextAction at capture-time creates friction that pushes thoughts back into the user's head — exactly what Jeeves should prevent.
- (c) is over-engineering. We *already* have `last_clarified_at` (Q12/13). A freshly-captured Task has `last_clarified_at = created_at` (the act of giving it a title and outcome description *is* a moment of clarification — the lightest possible). It then ages naturally into the re-clarify queue. No second timestamp needed.
- "Captured-not-yet-clarified" and "clarified-and-now-stale" both surface in the same Daily Planning re-clarify queue. From the user's perspective, both ask the same question: "what does this Task need from you?"
- Symmetry with (Q14) deferred-clarification-on-completion: in both cases the model permits "Task with no current NextAction" and the system surfaces it for re-clarification on the user's terms.

The implication for `last_clarified_at`: **creating a Task stamps it.** Even though the user did the bare minimum (typed a title), they've given the Task an outcome statement, which is the lightest form of clarification. The Task is "fresh" until something happens (time passing, a blocker clearing, etc.) that should pull it back into the queue.

So a captured-but-actionless Task is **fresh and actionless**. Daily Planning surfaces it not because it's stale, but because it has no current NextAction — that's the *other* axis. Two independent reasons to surface a Task in the planning queue:

- **Stale**: `last_clarified_at < latest_relevant_change`
- **Actionless**: `current_next_action IS NULL` and Task is not done/trashed

A Task can be one, the other, both, or neither.

Does (a) work, or do you want a separate "captured but never clarified" distinction?

---

## user

a works

---

## assistant

Good. Capture-and-clarify-later confirmed. A Task can exist as fresh+actionless; Daily Planning surfaces "stale" and "actionless" as two independent reasons.

---

**Question 16: Where do Tags attach — Task, NextAction, or both?**

Existing Tag system predates this redesign and sits on Task: `type IN ('context', 'project', 'area', 'label')`. We just added `'person'`. The new model has Contexts (deferred to v2) attaching to NextAction. Need to settle where Tags live going forward.

Concrete examples to think with:

| Example | Where does it belong? |
|---|---|
| Project tag "renovate kitchen" | Task — the outcome is part of the project |
| Area tag "home" | Task — life area scopes the outcome |
| Person tag "Trixy" (referenced by PersonBlocker) | Task — the wait is on the outcome's behalf |
| Person tag "Trixy" (because the *action* is "call Trixy") | NextAction? — the act involves Trixy |
| Existing `Tag(type='context')` like "@call" or "@home" | Used to be Task; properly belongs to action |
| Label tag "important" | Task — value judgment about the outcome |

Three cuts:

**(a) Tags stay on Task only.** Existing structure; no new join table. The action-flavored case ("Trixy" because action is "call Trixy") gets handled by NextAction Contexts in v2 (a separate concept), not by Tags. Existing `Tag(type='context')` like "@call" gets retired/migrated when Contexts land — until then, it stays Task-attached and we live with the imprecision.

**(b) Tags attach to either Task or NextAction (polymorphic).** Generalise the Tag system. Adds modelling complexity now to satisfy a use case (per-action tagging) we don't have a v1 user need for.

**(c) Tags on Task; NextAction inherits Task's tags for query purposes.** Action-level "involves Trixy" derives from Task's PersonBlocker referencing Trixy or Task being tagged Trixy. No separate NextAction-level tagging.

**Recommended answer: (a).**

Reasoning:
- Per the clarify-vs-organise memory: organising is a Task-level activity. The user files outcomes, not actions.
- Existing Tags don't change shape — the only new thing is `type='person'`. Migration cost stays at zero.
- The "Trixy because action is call-Trixy" case is real but rare and *already covered*: if you're waiting on Trixy for an outcome, the Task has a PersonBlocker → Tag(Trixy). Querying "what involves Trixy?" goes through PersonBlockers + Tags, no per-action Tag join needed.
- `Tag(type='context')` like "@call" is the awkward holdover. v2 Contexts (NextAction-attached predicates) will properly absorb it. Until then, tolerate the imprecision — `@call` on a Task is "this outcome's likely action is a call," which is loose but not wrong.
- Symmetry with deferring NextAction Contexts: we're explicitly deferring all action-level *gating* concepts to v2. Action-level *organising* (Tags on NextAction) goes with them. Don't split the deferral.
- (b) is generality without a use case.
- (c) is plausible but means we're committing now to NextAction-derived queries; cleaner to keep Tag → Task as the only join.

The implication: when v2 Contexts land, the existing `Tag(type='context')` rows get a migration story — convert to NextAction-level Time/Location Contexts where they fit, retire where they don't. v1 doesn't pay that cost.

Does (a) hold?

---

## user

Conceptually contexts can belong to task ar action. But considering there can be at most 1 next-action associated with a task, leaving a tag attached to task is perfectly workable IMHO. While I don't see any concrete reason for added complexity in implementation of splitting it across actions and tags, I'm not opposed to the refactor if and when the need comes, but no sooner.

---

## assistant

Confirmed — and your reasoning generalises nicely: at-most-one current NextAction means Task-level tags effectively cover action-level tags without information loss. v2 refactor only if a use case demands it.

---

**Question 17: Are terminal states (done / abandoned / trashed) reversible?**

Real cases the user might encounter:

1. **Task done → un-done**: "I marked it done but actually the outcome isn't there yet." Already partially established — TaskBlocker memory says blocking-Task un-done re-engages dependents' blockers, so this is supported.
2. **Task trashed → restored**: "I changed my mind, this outcome is back on the table."
3. **NextAction done → un-done** (fat-finger): "I tapped done by accident."
4. **NextAction abandoned → un-abandoned**: "Actually this approach was right, I gave up too soon."

Two cuts:

**(a) Field-flip reversibility.** `done_at`, `abandoned_at`, `trashed_at` are nullable timestamps. Reversing = setting them back to NULL. Trust the user; no audit-trail event for the undo.

**(b) Event-only.** Terminal states are immutable events. To "undo" you record a new event (e.g., "restored from trash" creates a new state record). Preserves history more strictly.

**Recommended answer: (a) field-flip reversibility, with one invariant guard.**

Reasoning:
- The user's reality is the source of truth. If they say "actually, not done," trust them. Adding an audit-trail entity for undos is over-engineering.
- The natural history is already preserved: NextActions are a list (current + history of done/abandoned ones); a Task's prior trashed-and-restored state is recoverable from the timestamp pattern (was non-null, now null) if we ever need it. We don't need a separate event log for undos in v1.
- Cheaper schema: no `task_state_events` table. Just nullable timestamps on the entities.
- (b) is the disciplined choice but pays modelling cost now for a forensic capability we don't yet need. v1 tolerance for "the truth is whatever the current row says."

**The one invariant guard — NextAction un-done with successor:**

When NextAction A is done and the user inline-clarifies a successor B, A.done_at is set and B is created as current. If the user then tries to un-done A, naive field-flip would produce two currents (A and B both with no done_at/abandoned_at), violating at-most-one-current.

Resolution: un-done on a NextAction is only a field-flip when no successor exists. If a successor was clarified in the meantime, un-done is an "undo last completion" operation that flips A back AND discards B (or marks B abandoned). This is a domain-level rule, not just a UI thing — the model needs to enforce at-most-one-current.

For Task `done` and `trashed`, no analogous invariant — straightforward field-flip.

For NextAction `abandoned`, same invariant as `done`: only field-flip if no successor; otherwise discard the successor.

Does (a) with this invariant guard work? Or do you want event-only history (b)?

---

## user

First of all, abandoned is not a terminal state. It's a temporary state after in-progress. It just means this task is no longer in-progress. It may go back to in-progress an hour later, the next day or it may go to trash. It just says "User is not working on this for now", not what will happen to it.

Second, Next action is light weight abstraction inside task to help the user focus. Not to suggest an implementation but as an example to explain the concept: think a text field. past actions is an array of text fields. next action getting done means it's moved from the text field and into an array. If there is a new next action you put it in the next field. If the user goes back to old next action, you move the new action into array and fill the text field with the old name. BTW Future next actions is also an array. it lives inside the description as a bullet list. Old actions live inside a journal/log of sorts. Now that I think about it this way, one very light weight implementation could be(don't lock it yet, there might be things I didn't consider yet): next action is a text field on task and we add an action text field to the TimeLog to store the current next-action and it serves as our history. Like I said, don't lock the implementation but that's to demonstrate how lite weight I'm considering next-action to be.

---

## assistant

Both corrections heard — they meaningfully simplify the model. Updating memories before moving on.

Memories updated. Restating the simplified model:

**Task lifecycle**: `in-progress ↔ abandoned`, with terminal exits to `done` or `trashed`. Abandoned is "not now," fully reversible, says nothing about future fate. Trashed is "outcome forever given up" — the only state that cascades to dependents.

**NextAction**: a lightweight cursor on Task, not an entity. Current = a text field. History = log entries (TimeLog or equivalent). Future thoughts = freeform notes. "Completing" = the cursor moves on; "abandoning the approach" = user rewrites the cursor; the old text lives in the log. No state machine, no successor invariants — Q17's NextAction-undo gymnastics evaporate.

The reversibility question collapses to just **Task done** and **Task trashed**: both field-flips. Q17 settled by simplification.

---

**Question 18: Does an abandoned Task surface anywhere, or is it dormant until the user reaches for it?**

GTD principle: nothing lives in the user's head. An abandoned Task ("not now") is a thought the user externalised so they don't have to remember it — but the system still owes them a way back to it.

Three cuts:

**(a) Dormant.** Abandoned Tasks vanish from Daily Planning, "needs re-clarification" derivations, the active list. Visible only via explicit search or a dedicated "abandoned" view. The user reaches for them when they're ready.

**(b) Periodically resurfaced.** Abandoned Tasks appear in Weekly Review (or equivalent low-frequency cadence) as a roll-call: "still abandoned? still want this? trash or pick back up?" Daily Planning leaves them alone.

**(c) Always present, just visually demoted.** Abandoned Tasks stay in everyday views with a subdued treatment. User sees them constantly but they don't compete for attention.

**Recommended answer: (b) periodically resurfaced.**

Reasoning:
- (a) is too close to "out of sight, out of mind" — risks becoming a graveyard. Tasks moulder forever without the user's explicit attention. Violates the GTD spirit of regular review.
- (c) makes Daily Planning noisy. If the user has 50 abandoned Tasks, demoting them visually still costs cognitive bandwidth every planning session. Defeats the purpose of "abandoned = not now."
- (b) honors both: abandoned means the user isn't bothered with it daily, AND the system guarantees a forced revisit at a meaningful cadence (Weekly Review). The user can always pull them up on-demand too.
- This aligns with the existing Phase 1 "weekly review" placeholder (per the milestone-phases memory — Phase 1 is paper-doable GTD core, weekly review is canonical).
- Implications for derivations: `last_clarified_at` keeps ticking. Abandoned Tasks accumulate "stale" status naturally. Weekly Review can sort by staleness.
- Phase 4 AI gets a clean job: "you abandoned X six weeks ago; the trigger event you mentioned has happened — pick it up?"

The `needs re-clarification` derivation should still apply to abandoned Tasks (the predicate fires regardless of state) — but Daily Planning filters them out. Weekly Review surfaces them by that same predicate.

Does (b) hold, or do you want abandoned dormant (a) / always present (c)?

---

## user

abandoned happens typically mid day. the user is confronted with a choice to resolve it during the evening shutdown down with Rollover, Back to Next or Maybe/Someday. until then they are visually demoted in the daily plan because the daily plan is immutable by design.

I'm assuming what you mean by abandoned in your question primarily is meant for the abandoned tasks that got moved back to next or someday. these will naturally fall into their respective cadence of review through `last_clarified_at`. No need for special treatment. at best we can surface in UI that this task had partial progress at some point.

---

## assistant

That clears it up — I had been collapsing two distinct things. Updating memories.

Locked in. Q18 settled by the cleaner decomposition: there is no long-term "abandoned" — only `active`/`someday`/`done`/`trashed`, with intra-day visual demotion being a today's-plan UI affordance and evening shutdown a forcing function.

---

We've covered a lot of #181's domain ground. Here's what's locked:

- **Tenets**: outcome-over-action; clarify ≠ organise; capture-then-clarify-later; completion ≠ clarification.
- **Entities**: Task (active/someday/done/trashed); NextAction as lightweight cursor + log history; Blockers (PersonBlocker event-cleared, TaskBlocker predicate-cleared); Tags-on-Task with new `type='person'`.
- **Predicates**: `last_clarified_at` derives "needs re-clarification"; "actionless" (no current next action) is a separate axis.
- **Rules**: cycle prevention on TaskBlocker; cascade only on `trashed`; un-done re-engages dependents; Contexts entirely deferred to v2.
- **Daily plan**: immutable today; mid-day demotion; evening shutdown resolves to Rollover/Back-to-Next/Someday.

Open threads I can think of that we *haven't* nailed down explicitly:
- Whether existing `Tag(type='context')` rows need any v1 handling (likely no — they coexist with v1 plumbing untouched, get their migration story when v2 Contexts land).
- Whether the engineering split for #181 v1 is one PR or a sequence (PR-A model migrations, PR-B PersonBlocker, PR-C TaskBlocker, PR-D `last_clarified_at` predicate).
- Whether #180's UX redesign sits on top of a stable #181 plumbing or whether the two ship interleaved.

Want to continue interviewing on any of those, or shall I step out and sketch the engineering plan for #181 v1 plumbing for your review?

---

## user

One thing that was clear for me was Blockers are seperate from contexts and we need to seperate the implementation for both. That leaves the question whether to just limit 181 scope and create a new issue for contexts or whether we should create individual issues for each type of blocker/context and make 181 the domain modelling parent for all of them. I'm tending towards the latter. What are your thoughts?

---

## assistant

Agree with (B). The case is strong:

- The domain modelling we just did is genuinely shared across Blockers AND Contexts — same vocabulary (clarify/organise, outcome/action, attachment-points), same predicate (`last_clarified_at`), same daily-plan/shutdown ritual. Splitting modelling and engineering across the same epic is what made #181 feel sprawling. Separating them clarifies both.
- Clean label discipline: per the `domain-modelling` label scope, #181 properly *is* the modelling work; children become engineering stories without that label.
- Each variant has independent milestoning and UX. PersonBlocker plumbing fits Phase 1; LocationContext probably needs OS hooks (Phase 3). Bundling them in one issue forces the longest pole to drag the rest.
- Variants are also independently shippable / deferrable. If TimeContext UX turns out trickier than expected, it shouldn't block PersonBlocker shipping.

**Proposed child shape** (for your review — I'll defer to you on creation and labels):

Under #181 (parent, `domain-modelling`):
- **PersonBlocker plumbing** — model + Tag(type='person') + clearing event. v1.
- **TaskBlocker plumbing** — model + cycle prevention + cascade-on-trash + computed cleared. v1.
- **Re-clarification surface** — `last_clarified_at` + derived "needs re-clarification" predicate + wire-up to existing Task surfaces. v1 — possibly bundled with the two above if scope is small enough; possibly separate if it touches enough surfaces.
- **TimeContext** — deferred (Phase 2-ish).
- **LocationContext** — deferred (Phase 2/3-ish, depends on OS hooks).
- **`Tag(type='context')` migration** — when Contexts land. Deferred.

#181 itself shrinks to: synthesis of the modelling decisions (linking to the memories we built up), pointers to the children, no engineering scope.

#180 (daily ritual redesign) sits adjacent and consumes plumbing as it lands — independent issue, doesn't need to be a child of #181.

One open question for you: do you want #181's body rewritten now to reflect this synthesis (and to point to the children once spawned), or do you want me to draft the children first and then update #181 last? Either order works; I'd default to drafting children first so #181's "see [child issues]" pointers are real on first read.
