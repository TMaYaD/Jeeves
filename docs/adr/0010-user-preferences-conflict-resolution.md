# ADR-0010: Per-key conflict resolution for `user_preferences`, with snooze floors departing from blanket LWW

## Status

Accepted.

## Context

`user_preferences` is a synced key-value store replicated by PowerSync. The v1 policy (recorded in CONTEXT.md and ARCHITECTURE.md) was blanket last-write-wins (LWW) on `updated_at`, applied implicitly by the engine with no code surface. Issue #306 surfaced two problems:

1. **Server-absent rows can wipe local values.** When a local row exists but the server snapshot omits it, a naive reconciliation deletes the local row — losing a preference the server simply hadn't heard of yet.
2. **Blanket LWW is wrong for some keys.** A "snooze until X" value is a *floor* the user should never see regressed. Under LWW, a later write carrying a stale snooze value would regress an active snooze and re-fire a notification the user silenced. Future list/set-shaped keys (filter selections, pinned items) would drop concurrent additions under LWW.

The reconciliation rule "server-absent → keep local" is made unambiguous by the **tombstone invariant**: deletion is modelled as a present row with `value = NULL`, never a physical removal, so an absent server row can only mean "never synced," never "deleted elsewhere."

## Decision

Introduce a **per-key conflict-strategy registry in code** (`app/lib/services/user_preferences_conflict.dart`) — a pure function mapping each key to one of `{ lww, maxTimestampValue, setMerge }`, with **`lww` as the non-destructive default** for any unregistered key. The registry is the executable source of truth the `docs/SYNC.md` conflict matrix is kept in lockstep with, and the seam future non-LWW keys register against (e.g. #323 migrates the Nudge `snoozed_until` key onto it).

**Snooze "until" keys arbitrate by `maxTimestampValue`, deliberately departing from blanket LWW:** among two live rows the later *value* wins (never regress the floor); a clear/un-snooze (tombstone) is arbitrated against a live value by LWW on `updated_at`, so a clear silences the snooze but a later re-snooze survives a stale clear.

`setMerge` (list union) is defined but has no production key today; it is provisioned so a future list/set key cannot ship under LWW that would silently drop concurrent additions.

`lww` keys continue to rely on PowerSync's built-in hold of pending CRUD mutations (its write-checkpoint mechanism) at runtime rather than a bespoke reconciliation pass; the registry governs the exceptions and the default.

## Consequences

- The conflict policy is now an auditable per-key contract rather than an implicit engine behaviour. #323 and any future key extend it by registering a strategy, not by editing prose.
- Snooze keys behave differently from every other key. A reviewer encountering `maxTimestampValue` needs this ADR to understand why it is not LWW; the trade-off accepted is that a snooze floor is never regressed at the cost of a stale-but-later value occasionally winning over a fresher-but-earlier one.
- Hard to reverse: once #323 and other keys depend on the registry seam, collapsing back to blanket LWW would reintroduce the snooze-regression and set-drop bugs.
- The engine-level reconciliation path (server-absent wipe) has no automated coverage in the current `NativeDatabase.memory()` harness; it is verified manually/on emulator. A standing PowerSync-client integration harness is deferred to its own issue.

If reviewers prefer strict LWW for snooze keys, the alternative is to accept and document the snooze-regression risk instead; this ADR records that we chose not to.
