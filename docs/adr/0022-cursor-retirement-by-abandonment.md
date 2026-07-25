# ADR-0022: Retire the next-action cursor by abandonment, not by drop

**Status:** Accepted
**Date:** 2026-07-25
**Context:** ADR-0001 story 9 (issue #479), epic #470. Builds on ADR-0004 (planned queue), ADR-0012 (clarification-neutral sweep), ADR-0017 (destructive-migration procedure), ADR-0018 (supersession without linkage), ADR-0019 (deterministic backfill ids).

## Decision

The next-action cursor columns on `todos` — chiefly `next_action_text` — are retired by **abandonment**, not by drop. They stay declared in Drift and Postgres and keep replicating indefinitely, while the app stops both reading and writing them at runtime. The `actions` table is the only grain for "what is this Outcome's next move?".

**Nothing in the running app reads or writes the cursor.** The single remaining consumer is the **one-time Drift v26 schema-upgrade backfill** (`gtd_database.dart`), which mints Actions for a pre-Action store: it runs once, at upgrade, before any watcher exists, and is guarded on the cursor columns' presence — which is precisely why `next_action_text` must stay declared in `tables.dart`. The startup reconciliation sweep is correspondingly reduced to a **single cursor-free pass**, `convergeMultiCurrentActions`, which retires the losers of an accidental multi-`current` set by the writers' deterministic winner rule and reads `actions` and nothing else.

This removes the invariant the dual-write era maintained — *blank cursor ⟺ no `current` row*, with a non-blank cursor holding exactly the current row's text. Nothing upholds it any more, and no future contributor should "restore" it. The individual cursor clears each role transition used to perform (demote, completion, abandon — the last added by #515) are all unnecessary once nothing writes the cursor, and their removal is safe for one reason only: **nothing reads the cursor back.**

**A runtime cursor-adoption pass was tried and deleted.** It minted a deterministic-id `current` Action for a live Outcome carrying a non-blank cursor **and no `actions` rows at all**, to adopt rows synced from a client predating the Actions table. Its safety argument was that every role transition leaves a row behind — `planned` after a demote, `done` after a completion, `superseded` after an abandon — so a zero-`actions` Outcome could only be one the app had never touched. **That argument was false.** `ActionDao.applyRemovePlannedAction` is a hard `DELETE` — the Remove-vs-Abandon distinction #478 deliberately shipped — and it is the only mutation that drives an Outcome's Action count to zero while the `todos` row survives. So on any store whose cursor was populated during the dual-write era, two taps (demote the current Action, then remove the planned row it became) left a live cursor over zero Action rows, and the next launch minted the just-deleted Action back as `current` and synced it to every device.

Deleting the pass outright — rather than adding a fourth guard — makes that resurrection **impossible by construction**, and lets `applyRemovePlannedAction` stay a hard delete. A guard phrased over role *transitions* can never be complete while one mutation leaves no row at all; a sweep that does not read the cursor has nothing to be wrong about.

## Trade-off

**Dropping the columns was rejected.** It is irreversible (AGENTS.md § Data Persistence), it is unschedulable — ADR-0017's pipeline cannot express rules-before-migration, and the sync bucket is `SELECT * FROM todos`, so a server-side drop makes the column vanish from every client at once — and, decisively, the Drift v26 backfill is *guarded on the cursor columns' presence*. Removing them would make that guard silently skip and strand every late-upgrading store with zero Action rows: empty Next list, no error, no log, no failing test. Columns cost nothing; a drop remains a follow-up proposal blocked on a demonstrated cost.

**A permanent derived cursor mirror was rejected** as indefinite double bookkeeping and a second source of truth that a future writer would eventually trust.

**The accepted cost is that a pre-Action client's rows render Actionless.** An Outcome created on a client that predates the `actions` table, and synced in, arrives carrying only a cursor; with adoption gone, nothing turns it into an Action and the Outcome shows no next action. Its text is **not lost** — the column still holds it and still replicates, and the v26 backfill still adopts it on a store that upgrades through that migration — it is merely unsurfaced on a device that already migrated. That is deliberately preferred to a runtime pass that can resurrect deleted work: a missing subtext is visible and recoverable by re-clarifying, whereas an Action reappearing after the user removed it is silent, propagates to every device, and looks to the user like the app undoing their decision.

Likewise, a cursor edit from a pre-retirement client is silently ignored on every Outcome. Losing a stale client's edit is deliberately preferred to letting it clobber Action-grain history: the inverse — the deleted Pass B and Pass A mode 1 — destroyed the user's current Action and stranded its `time_logs` attribution, which is unrecoverable.

**One signal is deliberately given up.** `ActionDao.applyCompleteCurrentAction` now writes nothing to `todos` at all, so completing an Action no longer bumps `todos.updated_at`. Any consumer of "the Outcome row changed" (server LWW arbitration, cross-device change detection) loses that edge. Watchers stay correct because the view-notify is unconditional (ADR-0010), and the notify must not be removed as "redundant" just because the write is gone — two list watchers name only `{todoTags, tags}` in `readsFrom`.

## Version skew

**The dependency on the narrowed sweep is intra-build, not a release gate.** Shipping the write removal in a build whose sweep still carries Pass B is catastrophic: blank cursors plus a live Pass B retires every current Action on the device at next launch. That is satisfied by merge order on `main` (the safe sweep landed first, in #517), which also keeps every commit on `main` deployable. It needs no separate release.

Ordering *releases* was considered and rejected as a protection, because it cannot work: **Pass B lives in already-shipped binaries that no future release ordering can reach.** A device left on a pre-retirement build will retire the cursorless Actions it syncs and propagate the loss. That residual risk is inherent to the change and is handled operationally — the owner controls every device and updates them all — not by sequencing. The general rule stands: atomic PRs, skew handled in code (versioned APIs, tolerant readers), never by deploy order.

**Downgrading across this change is hazardous.** After retirement a completed Action leaves a stale non-blank cursor beside its `done` row. Rolling back to a pre-retirement build makes the old mode 3 read that as drift and mint a fresh `current` Action, resurrecting finished work. Same class as Pass B, same non-fix: do not downgrade across this change.

**Once this has shipped, the narrowed sweep must never be reverted.** Reverting it while the writes are gone re-arms Pass B against a store full of cursorless current Actions, and re-arms cursor adoption against every Outcome whose Action rows a Remove has deleted.

Nothing here is schema-irreversible. The cursor is fully re-derivable from `actions`, so a revert is repairable with a one-shot Action→cursor re-mirror.
