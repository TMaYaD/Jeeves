# ADR-0049: An empty next action means the title

**Status:** Accepted. Applies the title-as-action coupling already shipped in
`ClarifyCard`, `ClarifyDraft.assemble` and inbox routing to the one surface that diverged
from it. Constrained by ADR-0001 (the `actions` rows are the only grain) and ADR-0024 (no
Outcome column holds a next-action phrase). Issue #691; the stall it removes was
introduced by #293.

## Context

Promoting an Outcome to **Next** through `ProcessToHandlers`' default-on `nextActionDialog`
modifier opens a dialog for a next-action phrase. Saving that dialog **empty** used to
route nothing and advance nothing: the user was returned to the same review card with no
way past it except inventing a phrase. The guard justified itself as keeping an Actionless
Outcome off the Next List — but CONTEXT.md § GTD Core excludes exactly one quadrant from
Next, *actionless **and** PersonBlocked*, so an undelegated Actionless Outcome is a
first-class member and no List-coherence rule was actually at stake.

The real cost sits in `TodoDao._needsReviewWhere`. Its third branch — Actionless and
undelegated — carries **no freshness gate**: a fresh `last_clarified_at` does not suppress
it. An Outcome left Actionless is in `getNeedsReview()` permanently, so "resolve to Next and
leave it Actionless" would satisfy the user's complaint for one tap and then re-break it
every morning. That is what rules out the tempting alternative, *Actionless by decision* —
an explicit "no distinct action needed" resolution. To work it would need a new stored fact,
a carve-out in the Actionless predicate or the review query, a re-arming rule, and a Next
List row offering the user nothing to engage with. That is a model change, not a bug fix.

## Decision

**An empty next-action phrase means the Outcome's title.** When a surface routes an Outcome
to Next or Waiting For with no phrase supplied, the title stands in — written only while the
Outcome is **Actionless** (via the atomic `setCurrentActionTextIfActionless`, so a
deliberate phrase is never clobbered) and skipped only when the title itself is blank. The
item therefore always resolves and advances; only an explicit **cancel** leaves it
unresolved, and the two are distinguished by the dialog's return *type* (`null` vs `''`),
never by emptiness alone.

Two consequences are deliberate. Clearing an existing phrase and saving does **not** retire
the Action — the fallback is Actionless-only, and **Abandon** is the affordance for
retirement; the codebase's standing bias is never to destroy typed text. And an Outcome with
a blank title **keeps the old stall**: with neither a phrase nor a title there is nothing to
stand in as the Action, and routing would manufacture exactly the permanently re-armed row
this ADR exists to avoid. That arm is near-unreachable through the UI (the clarify surfaces
disable the routing buttons while the title is blank) and is reached mainly by a synced-in
row.

The honest framing is that the phrase is *invited, not demanded*: CONTEXT.md defines a
**Project** as an Outcome requiring more than one Action over its lifetime, which makes the
single-Action Outcome the ordinary case — and for it "Call the dentist" is already the
physical next action. Nothing is fabricated by mirroring it.
