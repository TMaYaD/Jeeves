# Ceremonies, Rituals and Nudges

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

A **Ceremony** is a guided activity the user performs with the app's facilitation.
A **Ritual** is a Ceremony the app treats as integral to the practice, and carries
a **Cadence** and a **Nudge** to suggest it. This document is the map of that
machinery: how a Nudge decides it is visible, how Triggers fire, and how competing
Nudges are ordered.

For what the words mean, [CONTEXT.md § Ceremony Framework](../CONTEXT.md#ceremony-framework).
For where this sits in the system, [ARCHITECTURE.md § Ceremonies](ARCHITECTURE.md#ceremonies).
For the visual treatment of a Banner, [DESIGN.md](DESIGN.md).

## Performances

A Ceremony **performance** runs *not-started* → *in-progress* → *terminated*, and
termination splits two ways. A **completed** performance is one a Trigger may treat
as satisfying the Ritual; an **abandoned** one is treated as if it had not happened.
Performances accumulate over a Ritual's lifetime, and a Trigger may consult that
history as part of its predicate.

An abandoned performance's working state may **seed** the next performance,
restoring the user's place — the step, the per-item cursor, the recorded
selections. Seeding is in-memory only: it degrades to a fresh start after process
death, which is accepted rather than a defect. It changes neither the lifecycle nor
Trigger semantics — hygiene reads only the in-progress state, and completion
history records only completed performances.

The current Ceremonies are `focus_session_planning`, `focus_session_review`,
`periodic_review`, and inbox clarification.

## Nudge visibility

A Nudge's visibility is computed on every read, never stored. Only two facts are
persisted against it: `dismissed_at` and `snoozed_until`.

```text
visible =
    (some Trigger is currently firing)
  ∧ (no performance of this Ritual is in progress)    ← in-progress hygiene
  ∧ (snoozed_until is null or now > snoozed_until)
  ∧ (dismissed_at is earlier than the most recent Trigger firing edge)
```

**Dismiss is scoped to the current firing, not to a window.** It hides the Nudge
until some Trigger next fires under its own rules. It is deliberately not
period-scoped, so a Trigger that fires immediately after a dismiss re-surfaces the
Nudge — dismissing answers *this* suggestion, not the next one.

**Snooze is time-bound**, and comes in two grades. A **user-explicit** snooze
carries a duration the user chose. A **system-implicit** snooze is a default a
surface applies on its own, for a gesture too low-signal to read as a real answer.
A Trigger may borrow the default duration from its Cadence, but that is an explicit
reference in the Trigger, never a model-wide default.

**Completion is a Ceremony fact, not a Nudge state.** The Nudge does not centralise
it; each Trigger decides whether and how completion enters its own predicate.

**In-progress hygiene is the one centralised non-content rule.** While a
performance of this Ritual is in progress, its Nudge is hidden regardless of every
Trigger's state — surfacing a "plan your day" banner inside the planning wizard is
incoherent. Triggers stay autonomous about content; this rule is content-independent
and applies uniformly, which is why it lives at the Nudge level rather than being
duplicated into each Trigger.

## Triggers

A Trigger is an autonomous predicate with edge detection: it fires its Nudge to
visible when the predicate transitions false → true. A Nudge has one or more, they
are independent of each other and of Cadence period semantics, and each owns its
full domain logic — including any "is this stale enough to nag about again?" rule.

Two shapes exist today.

- The **Cadence Trigger** is the canonical one. It fires once per anchor-to-anchor
  period — *the clock has crossed into a new period and the Ritual has not been
  completed in it* — and refires at the next boundary.
- **Content-state Triggers** are predicates over the user's data, refiring whenever
  the predicate newly evaluates true mid-period. The only one today is the Weekly
  Review's: *the Next list is empty while Waiting For or Someday still holds items*.

A predicate may also carry **world-state preconditions** — facts that gate whether
the Ritual makes sense at all. These stay inside the Trigger rather than becoming
Ritual-level rules, so Triggers remain autonomous. Today's are FocusSession
lifecycle gates:

| Ritual | Predicate |
|---|---|
| Daily Planning | Past today's planning anchor, and no qualifying session exists since the last Evening Shutdown anchor |
| Evening Shutdown | The ES period has turned, a FocusSession is active, and ES has not been completed this period |

Evening Shutdown needs an active session because it *is* that session's Review
phase — without one it has nothing to operate on.

The Daily Planning gate is the subtle one. Day attribution is anchor-based, so a
session started since the last ES anchor means this period's planning already
happened and the Nudge stands down. A **stale** open session — started *before* the
last ES anchor — does not qualify, so Daily Planning re-arms and fires alongside
Evening Shutdown. Evening Shutdown wins that contest by priority, which is the
intended outcome: the user must close the stale session before opening a new one.

## Cadence

A Cadence has two properties, and the period runs anchor to anchor
([ADR-0008](adr/0008-cadence-as-anchor-with-period.md)).

- **shape** — the calendar pattern: daily, weekly, every-N-days. It also drives
  cadence-flavoured copy: "Today's Plan" at a daily cadence, "This Week's Review"
  at a weekly one.
- **anchor** — the moment within the shape on which period boundaries land: 8 AM
  for a daily cadence, Sunday 09:00 for a weekly one.

Whether a given anchor is hardcoded or read from synced preferences is an
implementation detail *inside* the Cadence; the model treats it as a Cadence
property either way. Daily Planning and Evening Shutdown are daily; Weekly Review
is every seven days. Some anchors are user-configurable today (Daily Planning's
notification time), others are not.

A Cadence belongs only to Rituals, and powers exactly one Trigger — the Cadence
Trigger. Ad-hoc Ceremonies have none: they happen when the user chooses.

## The Nudge queue

Individual Nudge predicates are independent of each other, which leaves one
question unanswered: when two are visible at once, which does a single-occupancy
surface show? The queue answers it, one layer above individual Nudges.

Visible Nudges are ordered by their **Ritual's priority**, hardcoded today:

```text
Weekly Review  >  Daily Planning  >  Evening Shutdown
```

Weekly Review ranks highest because it restores the trusted state Daily Planning
operates on — planning against a stale Next list violates the method. Evening
Shutdown is temporally last and rarely competes; its position is for completeness.

Surfaces consume the queue rather than reading Nudges directly:

- **Banner** — a single-occupancy in-app slot, renders the queue head.
- **Notification** — takes the queue head, so at most one Ritual notifies at a
  time. The OS could stack several, but doing so would hand the user contradictory
  guidance: *plan your day* alongside *your trusted list is stale, review first*.
- A future **Agenda** surface could consume the whole queue in order, giving a
  forward look at what is on the user's plate.

When the head becomes invisible — completed, dismissed, snoozed, hygiene, or its
Trigger flipping false — the next bubbles up and consuming surfaces re-render. The
queue is recomputed reactively from its members' predicates and priorities; nothing
about it is stored.

## Surfaces are projections

A Ritual has at most one Nudge, and a Nudge has zero or more surfaces. Surfaces
read Nudge state to render and write Nudge state on user action — nothing more.
Adding or removing one does not change what a Nudge is.

Each surface's action → transition mapping is calibrated to its **signal
fidelity**, which is the whole reason the two gestures differ:

| Surface | Gesture | Maps to | Why |
|---|---|---|---|
| Banner | ✕ | dismiss | An explicit in-app gesture; the user meant it |
| Banner | action button | user-explicit snooze | A duration the user chose |
| Notification | swipe away | system-implicit snooze | Low-signal — mass-dismiss fatigue makes it a poor read of intent |
| Notification | skip | dismiss | An explicit button, cadence-flavoured copy ("Skip today") |

Today each Ritual schedules its own Notification. Consolidating them behind the
queue, as the Banner already is, is the standing target.
