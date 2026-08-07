# Sync & Conflict Resolution

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

Jeeves is offline-first. Local writes go to the embedded SQLite store immediately, and are replicated between devices by the **op log** — signed ops over the minimal sync server — as soon as the device is enrolled and reachable ([ADR-0026](./adr/0026-minimal-sync-server.md), [ADR-0034](./adr/0034-sync-starts-at-enrolment.md)). This is the only client sync path; there is no replication engine on the device (#595).

This document is about **merge**: how two devices that wrote concurrently end up agreeing, with the focus on the `user_preferences` synced key-value store, whose keys are the ones where blanket last-write-wins is sometimes the wrong answer.

For the transport architecture see [ARCHITECTURE.md § Minimal Sync Server](./ARCHITECTURE.md#minimal-sync-server); for the vocabulary, [CONTEXT.md § Sync](../CONTEXT.md#sync).

## What "conflict" means here

There is no upload/download asymmetry to reason about. An authored op is durable in the outbox from the moment it is signed, and reduced state is a join semilattice ([ADR-0030](./adr/0030-merge-strategies-must-be-join-semilattices.md)) — so a write is never lost to a race with a pull, and a row is never wiped because a server snapshot omitted it. Every device reduces every op it receives, in whatever order it receives them, and lands on the same state.

What remains is one question per field: **two writes to the same field of the same entity, neither aware of the other — which value stands?**

## The tombstone invariant

Deletion in `user_preferences` is modelled as a **tombstone** — a present row with `value = NULL` — never a physical row removal (`UserPreferencesDao.set(userId, key, null)`). The invariant is what makes the merge rules unambiguous:

> A genuinely **absent** value can only mean "no device has ever written this key." A real cross-device **delete** arrives as a present tombstone, not an absence.

So a key that reads as absent is a key nobody has set, and "absent → keep whatever is local" can never swallow a legitimate delete. A delete is a value, not a gap.

The same shape holds at the entity level: the reducer tombstones an entity rather than forgetting it, which is why a rebuild of the domain read model from the log deletes a row it has to rather than silently resurrecting it (`sync/domain_rebuild.dart`).

## The strategy registry (executable contract)

Per-key conflict strategy lives in code, not just prose: `app/lib/services/user_preferences_conflict.dart`. It is the single source of truth this document's matrix is kept in lockstep with, and the seam future non-LWW keys register against.

```dart
enum ConflictStrategy { lww, maxTimestampValue, setMerge }

const preferenceConflictRegistry = <String, ConflictStrategy>{...};  // exact-match entries
ConflictStrategy strategyForKey(String key);          // registry → suffix rule → default lww
ResolvedPreference resolvePreferenceConflict(...);    // (key, local, other) → resolved value
ResolvedPreference resolveWithStrategy(...);          // strategy-explicit variant
```

`resolvePreferenceConflict` is a pure function, unit-tested in isolation (`app/test/services/user_preferences_conflict_test.dart`). The reducer reaches it through the `MergeStrategyRegistry` adapter in `app/lib/sync/merge_strategy.dart`.

### Strategies

- **`lww` (default, non-destructive).** The later write wins, ordered by **HLC** — not by `updated_at`, which is an ordinary replicated field a device could write out of order. Correct for scalars where the latest intent on any device should win. Ties break on member id, deterministically, so two devices never disagree about a tie.
- **`maxTimestampValue`.** For snooze "until" floors. Among two live writes the later *value* (parsed as a timestamp) wins, so a stale write can never regress an active snooze and re-fire a notification the user silenced. A **tombstone (clear/un-snooze) is arbitrated against a live value by LWW** — a clear silences the snooze, but a later re-snooze survives a stale clear, and a stale clear does not undo a fresher re-snooze. Any key ending in `snoozed_until` is classified here automatically.
- **`setMerge`.** Union of the two JSON-list values so concurrent additions on two devices both survive. **No production key uses this today**; it is provisioned so a new list/set-shaped key (filter selections, pinned items) cannot ship under naive LWW that would drop concurrent additions. New list/set keys **must** be registered as `setMerge` before use.

Every strategy owes ADR-0030's obligations: merge must be commutative, associative and idempotent. A strategy that is not is a divergence bug, not a preference.

### The default is safe for any future key

An unregistered key resolves as `lww`, which never *loses* a write: it selects the newer of the two by HLC and nothing else. That includes a tombstone, which the reducer treats as an ordinary value (see the matrix below) — so a later clear does win, and the key reads as absent afterwards. What LWW does not do is remove the row or discard the fresher of two writes, which is why it is the safe default: a key needs explicit registration only when *choosing the newer write* would be wrong (snooze floors, sets), not merely to be safe.

### Explicit registration

`preferenceConflictRegistry` is an exact-match `key → strategy` map consulted **before** the `snoozed_until` suffix rule and before the default, so an entry there always wins. Registering `lww` explicitly is redundant at runtime — the key would fall through to it anyway — but it records that the strategy was chosen and reviewed rather than inherited, which is the bar for a key whose arbitration a reader would otherwise have to re-derive. Keys registered explicitly are marked in the matrix below.

### Strategy selection is per op

The strategy is selected from the op alone. A `user_preferences` op that carries `value` carries its `key` too, and the reducer refuses one that does not, under `preference_value_without_key` — a logged-but-refused quarantine, not a decode failure. **Nothing stored is read to pick the strategy**, so two devices cannot arbitrate the same pair of writes under different lattices depending on which of them had already learned the key ([ADR-0033](./adr/0033-user-preferences-ops-carry-their-key.md)). `SyncClient.capture` runs the same guard before authoring, so the shape cannot be signed into an outbox either. The refusal is pinned by `user_preferences_value_without_key_is_refused` in `spec/sync/reducer_v1_vectors.json`.

## Conflict matrix — every current `user_preferences` key

The three cases are uniform per strategy:

| Strategy | one side only | both present, differing |
|---|---|---|
| `lww` | the present value stands | later HLC wins (a tombstone is a normal value) |
| `maxTimestampValue` | the present value stands | two live values: later "until" wins; tombstone vs live: LWW |
| `setMerge` | the present value stands | union of both lists |

Every current key, grouped by family:

| Key (family) | Type | Strategy | Rationale |
|---|---|---|---|
| `focus_settings_sprint_duration_minutes`, `focus_settings_break_duration_minutes` | int | `lww` | Scalar setting; latest intent wins |
| `focus_session_planning_settings_time_hour`, `…_time_minute`, `…_notification_enabled`, `…_banner_enabled`, `…_default_snooze_duration`, `…_default_time_estimate` | int / bool | `lww` | Scalar settings |
| `planning_banner_dismissed_date`, `planning_notification_skipped_date` | date | `lww` | Latest-intent scalar, not a set |
| `shutdown_ritual_completed_date`, `shutdown_banner_dismissed_date`, `shutdown_notification_skipped_date` | date | `lww` | Latest completion / suppression wins |
| `periodic_review_last_completed_at` | datetime | `lww` | Monotonic in normal use ⇒ coincides with max |
| `periodic_review_banner_dismissed_date`, `periodic_review_banner_enabled`, `periodic_review_notification_enabled`, `periodic_review_notification_hour`, `periodic_review_notification_minute`, `periodic_review_notification_skipped_date` | date / bool / int | `lww` | Scalar settings / suppression |
| `periodic_review_nudge_content_firing_edge` | datetime | `lww` | Latest firing edge wins |
| `clarify_mode` | string enum (`oneToOne` / `nToM`) | `lww` *(registered explicitly)* | Scalar mode selection; both modes read the same many-to-many storage, so either winner leaves every Capture and link valid |
| `planning_notification_snoozed_until`, `shutdown_notification_snoozed_until`, `periodic_review_notification_snoozed_until` | datetime | `maxTimestampValue` | Snooze floor must never regress; un-snooze is a tombstone |
| *(none today)* | list/set | `setMerge` | Provisioned for future filter/pin selections |

**Snooze arbitration departs deliberately from the blanket LWW default**: between two live values the later *value* wins so a floor never regresses, while a clear is arbitrated against a live value by last-write-wins.

## Derived identity, and why merge does not need to care about it

Two collections have a domain key that is not their `id` column: `focus_session_tasks` (the `(session, task)` pair) and `user_preferences` (the `(workspace, key)` pair). Their local DAO writes mint a row id of their own, so two devices creating the same logical row would otherwise fork into two entities that never merge.

They do not, because the id is **derived**: `focusSessionTaskIdFor(sessionId, taskId)` and `preferenceEntityId(workspace, key)` (`app/lib/sync/ids.dart`). Every device names the same entity, so the ordinary field-grain merge above applies unchanged, and the projector realigns the local row's `id` onto the derivation when it writes reduced state back (`app/lib/sync/domain_projector.dart`). Junction rows in `todo_tags`, `capture_outcomes` and `capture_tags` follow the same rule through their `*IdFor` helpers.

## What is asserted, and where

- **Merge semantics**: `app/test/sync/merge_strategy_test.dart`, `app/test/services/user_preferences_conflict_test.dart`, and the golden vectors in `spec/sync/reducer_v1_vectors.json` (shared with the server's Python reducer, so a divergence is caught cross-language).
- **Convergence end to end**: `app/test/sync/convergence_test.dart` and `full_day_convergence_test.dart` run two simulated devices through enrol → write → sign → append → pull → verify → reduce and assert byte-identical reduced state.
- **Projection**: `app/test/sync/projector_view_notify_test.dart` (a reduced-in row reaches the watching queries) and `domain_rebuild_test.dart` (a fresh domain store rebuilt from the log, tombstones included).
