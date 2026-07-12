# Sync & Conflict Resolution

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

Jeeves is offline-first. Local writes go to the embedded SQLite store immediately and are replicated to PostgreSQL by PowerSync when connectivity is available. This document describes how conflicts between a local row and the server's copy are resolved — with the focus on the `user_preferences` synced key-value store — and the [`todos` upload contract](#the-todos-upload-contract): which columns must round-trip verbatim through the REST schemas.

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

## The `todos` upload contract

A local write can also be lost by **schema drop on upload** — distinct from the two preference directions above. The connector uploads the full local row, but the backend's create/update schema silently ignores an unknown field (Pydantic's default `extra='ignore'`), the server stores its own default, and the next checkpoint download replicates that default back over the local value. The symptom is a field that "reverts" shortly after a write — issue #380's vanishing Inbox capture, where `clarified = false` was dropped by `TodoCreate` and flipped to the server default `true`.

The contract: **every client-owned column must round-trip verbatim** through the applicable create/update route and schema (`backend/app/todos/schemas.py`) — create-only fields like `id` (POST dedupe key) and `created_at` (server default when omitted) follow the behaviour noted per column below. Column ownership for `todos`:

| Column | Owner | Notes |
|---|---|---|
| `id` | client | UUID generated at capture; `POST /todos/` dedupes on it for idempotent retry |
| `title`, `notes`, `done_at`, `intent`, `priority`, `due_date`, `time_estimate`, `energy_level`, `capture_source` | client | round-trip via both schemas |
| `clarified` | client | `false` = still in the Inbox; REST default `true` when omitted |
| `last_clarified_at` | client | stamped per clarifying micro-act; drives the Stale predicate |
| `next_action_text` | client | the next-action cursor; NULL = Actionless |
| `last_next_action_completion_at` | client | stamped when a focus session closes with the task non-done |
| `time_spent_minutes` | client | cumulative focus-stint minutes |
| `created_at` | client, server default when omitted | offline captures keep their true capture time |
| `updated_at` | client | the server never stamps it |
| `user_id` | **server** | derived from the JWT; any client-sent value is ignored by design |
| `location_id` | unused | no DAO writes it today |

The payloads arrive shaped by PowerSync/Drift: booleans as SQLite integers (`0`/`1`), timestamps possibly in Drift's space-before-offset format (`2026-04-30T00:00:00.000 +05:30`). The schemas must accept both — a `422` would drop the entry via the fatal-`4xx` path (window 3 above).

The standing regression tripwire is `backend/tests/test_todos.py::test_connector_shaped_payload_roundtrips_client_state`, which POSTs a payload shaped exactly like a connector PUT and asserts every client-owned value persists. When adding a column to the Drift `Todos` table, add it to both schemas and to that test — or record it here as server-owned.
