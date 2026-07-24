# 19. Backfilled Actions get a deterministic dual-origin id

## Status

Accepted

## Context

Splitting the next-action cursor (`todos.next_action_text`) into first-class
Action rows (ADR-0001, story 1 — issue #471) has to backfill one `current`
Action per Outcome that has a cursor. That backfill runs in **two** places
that must converge on a single row: the server-side Alembic 0028 data
migration, and the client-side Drift v26 `onUpgrade` step (offline and
unauthenticated installs have no server to migrate them — CONTEXT.md). If the
two minted rows with independent random ids, a signed-in device that migrated
locally and then synced would upload a second row for an Outcome the server had
already backfilled, and reconciling them would need new server-side machinery.

## Decision

Both origins derive the backfilled Action's id deterministically:
`uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todo_id>")` — RFC-4122
URL-namespace uuid5, lowercase, computed identically in Python
(`_backfill_action_id_for`) and Dart (`backfillActionIdFor`). The scheme keys
on the Outcome, not on content, so re-running either backfill can never mint a
second Action for the same Outcome. Every backfilled field derives only from
replicated Outcome data (`text` verbatim; `energy_level` / `time_estimate`
copied; `created_at = COALESCE(last_clarified_at, created_at)`), so the two
origins produce field-identical rows, and the ADR-0015 upsert-on-replay path
collapses the duplicate upload with zero new reconciliation code. A shared
cross-language golden vector pins the id equality.

Note that `created_at = COALESCE(last_clarified_at, created_at)` is an
**upper-bound approximation** of when the backfilled Action was actually
defined: `last_clarified_at` stamps on non-action clarifying edits too (title,
notes, intent, due date, blockers), so the true cursor-set time may be earlier.
Determinism across origins is what the derivation buys, not historical
precision.

## Consequences

The ids are permanent identities in every store, so the scheme is effectively
irreversible once shipped — which is why this is recorded here rather than left
as a code comment like the existing junction-id precedents (`todoTagIdFor`,
`captureOutcomeIdFor`). The genuine alternative — random ids plus a server-side
reconciliation pass — was rejected because deterministic identity makes
convergence fall out of existing machinery. The trade-off is that the backfill
is a one-time snapshot: after it runs, ordinary cursor edits are not mirrored
onto the Action row, so a drift window opens between the cursor fields and the
backfilled rows. That window is accepted for story 1 (nothing reads `actions`
yet) and handed to the read-cutover story (#472) as an explicit reconciliation
obligation, precisely targetable because every backfilled row is findable as
`id = backfillActionIdFor(todo_id)`.
