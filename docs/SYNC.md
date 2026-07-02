# Sync & Conflict Resolution

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

Jeeves is offline-first. Local writes go to the embedded SQLite store immediately and are replicated to PostgreSQL by PowerSync when connectivity is available. This document describes how conflicts between a local row and the server's copy are resolved, with the focus on the `user_preferences` synced key-value store.

For the transport architecture (buckets, sync shapes, the BackendConnector, credentials), see [ARCHITECTURE.md § Sync Engine](./ARCHITECTURE.md#sync-engine). For the vocabulary (Sync Shape, Bucket, LWW, Tombstone), see [CONTEXT.md § Sync](../CONTEXT.md#sync).

## The two directions of a preference conflict

A `user_preferences` write can be lost in two mirror-image ways:

- **Upload side** — the local write never reaches the server. Guarded by `JevesBackendConnector.uploadData()`, which routes every table to a REST endpoint and throws for any unmapped table so the CRUD queue is never silently drained. A fatal `4xx` on a `user_preferences` row additionally trips a debug assert (`backend_connector.dart`) so a systematic drop surfaces in development rather than silently losing data.
- **Download / reconciliation side** — the local row exists, the server snapshot omits it, and the next pull deletes the local row. This is the case this document's conflict rules govern.

## The tombstone invariant

Deletion in `user_preferences` is modelled as a **tombstone** — a present row with `value = NULL` — never a physical row removal (`UserPreferencesDao.set(userId, key, null)`). This single invariant is what makes the reconciliation rules unambiguous:

> A genuinely **absent** server row can only mean "the server has never heard of this key." A real cross-device **delete** arrives as a present tombstone row, not an absence.

Therefore the rule **server-absent → keep local** can never swallow a legitimate delete. A delete is a value, not a gap.

## PowerSync reconciliation behaviour (write-checkpoint)

PowerSync keeps CRUD-queue mutations applied on top of synced data and holds them until a downloaded checkpoint reaches the *write checkpoint* issued after `uploadData()` succeeds. The wipe windows and whether the engine self-heals:

| Window | Scenario | Engine behaviour |
|---|---|---|
| 1. Pending upload | Local write queued, not yet uploaded; pull omits the row | Held — the CRUD-queue mutation stays applied until its write checkpoint is reached. No local wipe. |
| 2. Replication lag | REST returned 201, row in Postgres, not yet in the publication snapshot | Held — the write checkpoint is not reached until replication catches up. |
| 3. Fatal drop | Connector hits a non-retryable `4xx`, skips the entry, the write checkpoint advances | **Not covered by the engine.** The next pull deletes the local row. This is the residual risk, and it is a connector/backend concern, not a reconciliation-rule concern. |

Windows 1–2 are the engine's built-in "hold pending mutations" guarantee; plain last-write-wins keys ride on it and need no bespoke download-arbitration code. Window 3 is prevented by keeping the backend routes idempotent/permissive so a legitimate write never `4xx`s; the connector's loud-in-debug assert only *detects* such a drop during development (it does not prevent the wipe in release).

> **No automated coverage of the engine path.** The delete-on-absent behaviour is a PowerSync view/engine effect. The entire Dart test harness runs on `NativeDatabase.memory()` — a real SQLite table with no PowerSync engine — so windows 1–3 cannot be reproduced in unit tests. They are verified manually/on emulator (see [TESTING.md § Sync conflict resolution](./TESTING.md#sync-conflict-resolution-manual)). A standing PowerSync-client + docker-compose integration harness is deferred to its own infra issue.

## The strategy registry (executable contract)

Per-key conflict strategy lives in code, not just prose: `app/lib/services/user_preferences_conflict.dart`. It is the single source of truth this document's matrix is kept in lockstep with, and the seam future non-LWW keys register against (e.g. the Nudge `snoozed_until` key migrated onto this contract in #323).

```dart
enum ConflictStrategy { lww, maxTimestampValue, setMerge }

ConflictStrategy strategyForKey(String key);          // registry lookup; default lww
ResolvedPreference resolvePreferenceConflict(...);    // (key, local, server) → resolved value
ResolvedPreference resolveWithStrategy(...);          // strategy-explicit variant
```

`resolvePreferenceConflict` is a pure function covering the three cases below; it is unit-tested in isolation (`app/test/services/user_preferences_conflict_test.dart`). `lww` keys rely on PowerSync's engine hold (windows 1–2) at runtime; the registry actively governs the exceptions (`maxTimestampValue`, `setMerge`) and every future key.

### Strategies

- **`lww` (default, non-destructive).** The row with the later `updated_at` wins. Correct for scalars where the latest intent on any device should win. Ties resolve to the server copy.
- **`maxTimestampValue`.** For snooze "until" floors. Among two live rows the later *value* (parsed as a timestamp) wins, so a stale write can never regress an active snooze and re-fire a notification the user silenced. A **tombstone (clear/un-snooze) is arbitrated against a live value by LWW on `updated_at`** — a clear silences the snooze, but a later re-snooze survives a stale clear (and a stale clear does not undo a fresher re-snooze). Any key ending in `snoozed_until` is classified here automatically.
- **`setMerge`.** Union of the two JSON-list values so concurrent additions on two devices both survive. **No production key uses this today**; it is provisioned so a new list/set-shaped key (filter selections, pinned items) cannot ship under naive LWW that would drop concurrent additions. New list/set keys **must** be registered as `setMerge` before use.

### The default is safe for any future key

An unregistered key resolves as `lww`, which is non-destructive: it never deletes a value, it only prefers the newer of two present values, and server-absent always keeps local. A key only needs explicit registration when blanket LWW would be *wrong* (snooze floors, sets), not merely to be safe.

## Conflict matrix — every current `user_preferences` key

The three cases are uniform per strategy:

| Strategy | local-only (server absent) | server-only (local absent) | both present, differing |
|---|---|---|---|
| `lww` | keep local | adopt server | later `updated_at` wins (tombstone is a normal value) |
| `maxTimestampValue` | keep local | adopt server | two live rows: later "until" value wins; tombstone vs live: LWW on `updated_at` |
| `setMerge` | keep local | adopt server | union of both lists |

Every current key, grouped by family:

| Key (family) | Type | Strategy | Rationale |
|---|---|---|---|
| `focus_settings_sprint_duration_minutes`, `focus_settings_break_duration_minutes` | int | `lww` | Scalar setting; latest intent wins |
| `focus_session_planning_settings_time_hour`, `…_time_minute`, `…_notification_enabled`, `…_banner_enabled`, `…_default_snooze_duration` | int / bool | `lww` | Scalar settings |
| `planning_banner_dismissed_date`, `planning_notification_skipped_date` | date | `lww` | Latest-intent scalar, not a set |
| `shutdown_ritual_completed_date`, `shutdown_banner_dismissed_date`, `shutdown_notification_skipped_date` | date | `lww` | Latest completion / suppression wins |
| `periodic_review_last_completed_at` | datetime | `lww` | Monotonic in normal use ⇒ coincides with max |
| `periodic_review_banner_dismissed_date`, `periodic_review_banner_enabled`, `periodic_review_notification_enabled`, `periodic_review_notification_hour`, `periodic_review_notification_minute`, `periodic_review_notification_skipped_date` | date / bool / int | `lww` | Scalar settings / suppression |
| `periodic_review_nudge_content_firing_edge` | datetime | `lww` | Latest firing edge wins |
| `planning_notification_snoozed_until`, `shutdown_notification_snoozed_until`, `periodic_review_notification_snoozed_until` | datetime | `maxTimestampValue` | Snooze floor must never regress; un-snooze is a tombstone |
| *(none today)* | list/set | `setMerge` | Provisioned for future filter/pin selections |

**Snooze arbitration departs deliberately from the blanket LWW default** — see [ADR-0011](./adr/0011-user-preferences-conflict-resolution.md).

## Sign-in migration

A separate LWW pass runs once at sign-in, when local-only rows (`user_id = 'local'`) are reassigned to the authenticated user (`LocalDataMigrationService.migrate`, `migration_service.dart`). It applies the `lww` strategy in SQL — reassigning non-conflicting keys and, for conflicting keys, keeping the row with the newer `updated_at`. This is the account-merge path, distinct from the ongoing PowerSync download reconciliation above.
