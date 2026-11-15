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
as satisfying the Ritual; an **abandoned** one is treated as if it had not happened,
except that a *started* Daily Planning, Evening Shutdown or Weekly Review fires the
**Unfinished Trigger**.
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

## Weekly Review sessions

The intro offers Everything by default, plus 15, 30 and 60-minute budgets when
strictly shorter than the full estimate. At two minutes per item, 15 minutes
selects seven items from one pool across all steps. Selection preserves the
existing order within each step. The ranker is replaceable through
`periodicReviewRankerProvider`.

Inbox Captures come first in every session, then Bypassed Outcomes. Every
other candidate, from any step, is ranked least-recently-clarified first (never clarified first), then by
creation time, id and step, ascending. Planless, Stale, Actionless and Waiting
For Outcomes get no priority of their own.

Each Outcome is ranked once. A Bypassed Outcome groups into the Decide Bypassed
Outcomes step, which follows Process Inbox and appears only when the session
holds one; it is never also a Waiting For or Next item, and one cut from a short
session appears in no step. The step has no Skip: each Outcome is moved to
Someday/Maybe or Trashed, and the footer offers only Back until all are decided.
Its completion line says how many Bypassed Outcomes wait for a longer session.

The first partial session opens a seven-day review period. Outcomes clarified
since it opened count as covered, including Keep and clarification on other
surfaces. Captures count only when they leave the Inbox: **Keep on a Capture
leaves it pending**, so it returns next session. Skip likewise leaves an item
pending in a partial session. Progress survives process death; the precise
in-session cursor remains transient.

Done on any session, partial or final, sets the last-review time: the review is
due seven days after it, or seven days after the first Capture or Outcome for a
user who has never reviewed. A partial summary shows the remaining count from
current storage and Done ends only that sitting. A session containing all remaining items completes the review
on Done, even with skips, preserving the full-review behaviour. An unfinished
review expires seven days after opening and starts fresh. Nudge cadence and
in-progress suppression continue to apply.

## Nudge visibility

A Nudge's visibility is computed on every read, never stored. Only two facts are
persisted against it: `dismissed_at` and `snoozed_until`.

```text
visible =
    (some Trigger is currently firing)
  ∧ (no performance of this Ritual is in progress)    ← in-progress hygiene
  ∧ (snoozed_until is null or now > snoozed_until)
  ∧ (dismissed_at is null or earlier than the most recent Trigger firing edge)
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

Three shapes exist today.

- The **Cadence Trigger** is the canonical one. It fires once per anchor-to-anchor
  period — *the clock has crossed into a new period and the Ritual has not been
  completed in it* — and refires at the next boundary.
- **Content-state Triggers** are predicates over the user's data, refiring whenever
  the predicate newly evaluates true mid-period. The only one today is the Weekly
  Review's: *the Next list is empty while Waiting For or Someday still holds items*.
- The **Unfinished Trigger** is every Ritual's: *a performance was started and left
  without finishing*. It fires at once, whether or not the Ritual is due, and lives in
  memory on this device. While it fires the Banner and the Now screen's empty state
  use continue wording. The Weekly Review's ends when a session is finished. Daily
  Planning is *started* once the user proceeds past the intro (a latch on the draft),
  and ends when any FocusSession opens or the draft resets. Evening Shutdown is
  started when its first step shows, and ends when that session closes, with or
  without the Ceremony. It stays out of the pure firing-edge functions the
  Notification planner reads, so leaving a Ceremony never re-arms a skipped
  Notification. While Evening Shutdown is the head the Now screen keeps its shutdown
  callout, so its continue wording shows on the other shell screens.

The Weekly Review's Cadence Trigger fires while the review is due and refires every
day, so a swipe holds for the rest of the day and the Nudge returns tomorrow.

A predicate may also carry **world-state preconditions** — facts that gate whether
the Ritual makes sense at all. These stay inside the Trigger rather than becoming
Ritual-level rules, so Triggers remain autonomous. Today's are FocusSession
lifecycle gates:

| Ritual | Predicate |
|---|---|
| Daily Planning | Past today's planning time, before the Evening Shutdown time, no session is open, and no session started today |
| Evening Shutdown | A FocusSession is open and has reached its due time, and ES has not been completed this period |

Evening Shutdown needs an open session because it *is* that session's Review
phase — without one it has nothing to operate on.

The two Triggers never overlap: while any session is open Daily Planning is not
offered, and Evening Shutdown asks the user to close it first
([ADR-0020](adr/0020-sessions-never-auto-close-anchor-day-attribution.md), [ADR-0049](adr/0049-a-session-counts-as-the-days-plan-only-on-the-day-it-started.md)).

- **Daily Planning** counts a session as the day's plan only if it started on that
  calendar day, open or closed. A session started in the Evening belongs to that
  Evening, so Daily Planning is offered again at the next planning time. From the
  Evening Shutdown time until the next planning time it is idle.
- **Evening Shutdown due time.** A session started before the Evening Shutdown time
  is due at it. A session started at or after it is due at its start plus the
  available time chosen in Daily Planning — but never later than the next planning
  time. The available time is read from the preference Daily Planning stores each
  time a session opens. The rule is provisional.
- **Staying visible.** Once due, Evening Shutdown shows through midnight until the
  session is closed. A swipe hides it until the next planning time or the next
  Evening Shutdown time, whichever comes first.
- **Settings refuse equal times.** Daily Planning and Evening Shutdown cannot be set
  to the same time, so no predicate carries a tie rule.

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
Weekly Review  >  Evening Shutdown  >  Daily Planning
```

Weekly Review ranks highest because it restores the trusted state the other two
operate on — planning against a stale Next list violates the method. Evening
Shutdown outranks Daily Planning
([ADR-0020](adr/0020-sessions-never-auto-close-anchor-day-attribution.md)).

**Inbox too full** sits ahead of the queue, not in it. It is not a Ritual: it has
no Trigger, no dismiss or snooze, and no Notification, and it clears the moment
the Inbox holds 50 Captures or fewer. It shows as a Banner only; its tap opens
Inbox clarification, one Capture at a time, oldest first, until the Inbox is
empty or the user leaves. The Now screen shows no Banner: the surface head (Inbox
too full, else the queue head) fills the Today's Tasks empty state while no open
session carries tasks, and the title bar's sun action opens Daily Planning while
Inbox too full or the Weekly Review holds that space.

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
| Banner | horizontal swipe | dismiss | An explicit in-app gesture; the user meant it |
| Banner | action button | user-explicit snooze | A duration the user chose |
| Notification | swipe away | system-implicit snooze | Low-signal — mass-dismiss fatigue makes it a poor read of intent |
| Notification | skip | dismiss | An explicit button, cadence-flavoured copy ("Skip today"; "Skip this week" for Weekly Review) |

The Notification surface is a projection of the queue to fire instants. An OS
notification fires while the app is not running, so the scheduler asks, for each
Ritual's notification time over the coming week, whether that Ritual would hold
the queue head then — over the same predicates the live queue uses, with current
facts frozen — and arms only those. It re-plans whenever the facts change and
whenever the app opens or resumes. Reminders are planned seven days ahead and no
further, so they stop if the app is not opened for seven days.
