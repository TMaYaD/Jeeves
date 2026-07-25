# ADR-0022: Retire the next-action cursor by abandonment, not by drop

**Status:** Accepted
**Date:** 2026-07-25
**Context:** ADR-0001 story 9 (issue #479), epic #470. Builds on ADR-0004 (planned queue), ADR-0012 (clarification-neutral sweep), ADR-0017 (destructive-migration procedure), ADR-0018 (supersession without linkage), ADR-0019 (deterministic backfill ids).

## Decision

The next-action cursor columns on `todos` — chiefly `next_action_text` — are retired by **abandonment**, not by drop. They stay declared in Drift and Postgres and keep replicating indefinitely, while the app stops both reading and writing them. The `actions` table is the only grain for "what is this Outcome's next move?".

The startup reconciliation is correspondingly narrowed to a monotone **adoption** pass: it mints a `current` Action only for an Outcome that carries a non-blank cursor **and has no `actions` rows at all**. It never overwrites an Action's text and never retires one. A separate, permanent, cursor-free pass converges an accidental multi-`current` set.

This removes the invariant the dual-write era maintained — *blank cursor ⟺ no `current` row*, with a non-blank cursor holding exactly the current row's text. Nothing upholds it any more, and no future contributor should "restore" it. In particular, the individual cursor clears that each role transition used to perform (demote, completion, abandon — the last added by #515) are all unnecessary once nothing writes the cursor: the `planned` / `done` / `superseded` row each transition leaves behind is itself what stops the adoption pass minting a replacement.

## Trade-off

**Dropping the columns was rejected.** It is irreversible (AGENTS.md § Data Persistence), it is unschedulable — ADR-0017's pipeline cannot express rules-before-migration, and the sync bucket is `SELECT * FROM todos`, so a server-side drop makes the column vanish from every client at once — and, decisively, the Drift v26 backfill is *guarded on the cursor columns' presence*. Removing them would make that guard silently skip and strand every late-upgrading store with zero Action rows: empty Next list, no error, no log, no failing test. Columns cost nothing; a drop remains a follow-up proposal blocked on a demonstrated cost.

**A permanent derived cursor mirror was rejected** as indefinite double bookkeeping and a second source of truth that a future writer would eventually trust.

**The accepted cost is a bounded divergence.** A cursor edit from a pre-retirement client, on an Outcome that already has Action rows, is silently ignored by up-to-date clients. Losing a stale client's edit is deliberately preferred to letting it clobber Action-grain history: the inverse — the deleted Pass B and Pass A mode 1 — destroyed the user's current Action and stranded its `time_logs` attribution, which is unrecoverable.

**One signal is deliberately given up.** `ActionDao.applyCompleteCurrentAction` now writes nothing to `todos` at all, so completing an Action no longer bumps `todos.updated_at`. Any consumer of "the Outcome row changed" (server LWW arbitration, cross-device change detection) loses that edge. Watchers stay correct because the view-notify is unconditional (ADR-0010), and the notify must not be removed as "redundant" just because the write is gone — two list watchers name only `{todoTags, tags}` in `readsFrom`.

## Version skew

**The dependency on the narrowed sweep is intra-build, not a release gate.** Shipping the write removal in a build whose sweep still carries Pass B is catastrophic: blank cursors plus a live Pass B retires every current Action on the device at next launch. That is satisfied by merge order on `main` (the safe sweep landed first, in #517), which also keeps every commit on `main` deployable. It needs no separate release.

Ordering *releases* was considered and rejected as a protection, because it cannot work: **Pass B lives in already-shipped binaries that no future release ordering can reach.** A device left on a pre-retirement build will retire the cursorless Actions it syncs and propagate the loss. That residual risk is inherent to the change and is handled operationally — the owner controls every device and updates them all — not by sequencing. The general rule stands: atomic PRs, skew handled in code (versioned APIs, tolerant readers), never by deploy order.

**Downgrading across this change is hazardous.** After retirement a completed Action leaves a stale non-blank cursor beside its `done` row. Rolling back to a pre-retirement build makes the old mode 3 read that as drift and mint a fresh `current` Action, resurrecting finished work. Same class as Pass B, same non-fix: do not downgrade across this change.

**Once this has shipped, the narrowed sweep must never be reverted.** Reverting it while the writes are gone re-arms Pass B against a store full of cursorless current Actions.

Nothing here is schema-irreversible. The cursor is fully re-derivable from `actions`, so a revert is repairable with a one-shot Action→cursor re-mirror.
