# Sync & Conflict Resolution

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

Jeeves is offline-first. Local writes go to the embedded SQLite store immediately and are replicated to PostgreSQL by PowerSync when connectivity is available. This document describes how conflicts between a local row and the server's copy are resolved — with the focus on the `user_preferences` synced key-value store — and the [`todos`](#the-todos-upload-contract) and [focus-session](#the-focus-session-upload-contract) upload contracts: which columns must round-trip verbatim through the REST schemas.

For the transport architecture (buckets, sync shapes, the BackendConnector, credentials), see [ARCHITECTURE.md § Sync Engine](./ARCHITECTURE.md#sync-engine). For the vocabulary (Sync Shape, Bucket, LWW, Tombstone), see [CONTEXT.md § Sync](../CONTEXT.md#sync).

## The two directions of a preference conflict

A `user_preferences` write can be lost in two mirror-image ways:

- **Upload side** — the local write never reaches the server. Guarded by `JeevesBackendConnector.uploadData()`, which routes every table to a REST endpoint and throws for any unmapped table so the CRUD queue is never silently drained. A non-retryable `4xx` is classified per status ([ARCHITECTURE.md § Upload-error policy](./ARCHITECTURE.md#upload-error-policy)) and dead-lettered — recorded in the local `sync_dead_letters` table with its payload and surfaced through the sync indicator — never silently dropped. On a `user_preferences` row a dead-letter additionally trips a debug assert (`backend_connector.dart`) so a systematic rejection surfaces in development. `POST /user_preferences/` follows the shared [create-dedupe contract](#the-create-dedupe-contract): a same-user id replay upserts the submitted `value`/`updated_at` and converges — consistent with, not a substitute for, the reconciliation strategies below (the server route is last-arrival for the row it owns).
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
| 3. Dead-lettered upload | Connector hits a non-retryable `4xx`, dead-letters the entry, the write checkpoint advances | **Not covered by the engine.** The next pull can still delete the local row — but the entry's payload is preserved in `sync_dead_letters` and the failure is surfaced via the sync indicator, so the write is diagnosable rather than silently lost. |

Windows 1–2 are the engine's built-in "hold pending mutations" guarantee; plain last-write-wins keys ride on it and need no bespoke download-arbitration code. Window 3 is prevented by keeping the backend routes idempotent/permissive so a legitimate write never `4xx`s; if one does, the connector records a dead letter (payload + response body), the sync indicator shows the error, and debug builds additionally assert on `user_preferences` rows. Recording preserves the evidence and surfaces the failure — it does not stop the read-side wipe of the local row in release.

> **No automated coverage of the engine path.** The delete-on-absent behaviour is a PowerSync view/engine effect. The entire Dart test harness runs on `NativeDatabase.memory()` — a real SQLite table with no PowerSync engine — so windows 1–3 cannot be reproduced in unit tests. They are verified manually/on emulator (see [TESTING.md § Sync conflict resolution](./TESTING.md#sync-conflict-resolution-manual)). A standing PowerSync-client + docker-compose integration harness is deferred to its own infra issue.

## The strategy registry (executable contract)

Per-key conflict strategy lives in code, not just prose: `app/lib/services/user_preferences_conflict.dart`. It is the single source of truth this document's matrix is kept in lockstep with, and the seam future non-LWW keys register against (e.g. the Nudge `snoozed_until` key migrated onto this contract in #323).

```dart
enum ConflictStrategy { lww, maxTimestampValue, setMerge }

const preferenceConflictRegistry = <String, ConflictStrategy>{...};  // exact-match entries
ConflictStrategy strategyForKey(String key);          // registry → suffix rule → default lww
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

### Explicit registration

`preferenceConflictRegistry` is an exact-match `key → strategy` map consulted **before** the `snoozed_until` suffix rule and before the default, so an entry there always wins. Registering `lww` explicitly is redundant at runtime — the key would fall through to it anyway — but it records that the strategy was chosen and reviewed rather than inherited, which is the bar ADR-0011 sets for a key whose arbitration a reader would otherwise have to re-derive. Keys registered explicitly are marked in the matrix below.

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
| `clarify_mode` | string enum (`oneToOne` / `nToM`) | `lww` *(registered explicitly)* | Scalar mode selection; both modes read the same many-to-many storage, so either winner leaves every Capture and link valid |
| `planning_notification_snoozed_until`, `shutdown_notification_snoozed_until`, `periodic_review_notification_snoozed_until` | datetime | `maxTimestampValue` | Snooze floor must never regress; un-snooze is a tombstone |
| *(none today)* | list/set | `setMerge` | Provisioned for future filter/pin selections |

**Snooze arbitration departs deliberately from the blanket LWW default** — see [ADR-0011](./adr/0011-user-preferences-conflict-resolution.md).

## Sign-in migration

A separate LWW pass runs once at sign-in, when local-only rows (`user_id = 'local'`) are reassigned to the authenticated user (`LocalDataMigrationService.migrate`, `migration_service.dart`). It applies the `lww` strategy in SQL — reassigning non-conflicting keys and, for conflicting keys, keeping the row with the newer `updated_at`. This is the account-merge path, distinct from the ongoing PowerSync download reconciliation above.

## The create-dedupe contract

Every connector-facing POST create route dedupes on the client-generated `id` so PowerSync's at-least-once upload is idempotent. Two route shapes dedupe differently (ADR-0015).

**Top-level row create routes** — `todos`, `tags`, `focus_sessions`, `time_logs`, `captures`, `user_preferences`:

- **Same-user id match → upsert-on-replay.** Apply the submitted client-owned columns to the stored row (`model_dump(exclude_unset=True)`, with the dedupe key `id` and server-owned `user_id` never applied) and return the row `2xx`. A consolidated replay carrying newer offline edits — the window-3 divergence: a persisted PUT whose ack was lost, then edited offline and re-sent — converges the server row instead of reverting the edit one checkpoint download later. An **omitted** field is left as stored (the connector sends the full row, so real convergence still happens; a partial direct-REST retry stays safe — this is the #380 guard, `test_create_idempotent_retry_keeps_clarified`). `POST /todos/` additionally excludes the junction-owned `tags` (tag-set convergence flows through `todo_tags`, not the todo route) and the legacy `state` field from the applied columns.
- **Cross-user id collision → `409`.** A genuine anomaly, not a replay.

**Junction routes** — `todo_tags`, `capture_outcomes`, `capture_tags`, `focus_session_tasks` — do **not** upsert fields (their rows are immutable-or-nearly-so). They add the domain relation as a second dedupe key: a same-id/same-relation replay returns the stored row (`2xx`); a same-id/**different**-relation is a real anomaly (`409`). Parent ownership is enforced separately (`404`), so a cross-user id reuse necessarily differs in its `(parent, child)` pair and surfaces as that relation-mismatch `409` rather than a dedicated cross-user check.

Strict field-compare-`409` on mismatch was rejected (PR #422): it dead-letters the exact data it should converge, violating window 3. The upsert is unconditional (last-arrival, matching the PATCH routes); ADR-0015 records the declined `updated_at`-guarded variant. The per-table sections below reference this rule.

## The `todos` upload contract

A local write can also be lost by **schema drop on upload** — distinct from the two preference directions above. The connector uploads the full local row, but the backend's create/update schema silently ignores an unknown field (Pydantic's default `extra='ignore'`), the server stores its own default, and the next checkpoint download replicates that default back over the local value. The symptom is a field that "reverts" shortly after a write — issue #380's vanishing Inbox capture, where `clarified = false` was dropped by `TodoCreate` and flipped to the server default `true`.

The contract: **every client-owned column must round-trip verbatim** through the applicable create/update route and schema (`backend/app/todos/schemas.py`) — create-only fields like `id` (POST dedupe key) and `created_at` (server default when omitted) follow the behaviour noted per column below. Column ownership for `todos`:

| Column | Owner | Notes |
|---|---|---|
| `id` | client | UUID generated at capture; `POST /todos/` dedupes on it — a same-user replay upserts the submitted scalar columns and converges (the create-dedupe contract above), tag-set convergence flowing through `todo_tags` |
| `title`, `notes`, `done_at`, `intent`, `priority`, `due_date`, `time_estimate`, `energy_level`, `capture_source` | client | round-trip via both schemas |
| `clarified` | client | `false` = still in the Inbox; REST default `true` when omitted |
| `last_clarified_at` | client | stamped per clarifying micro-act; drives the Stale predicate |
| `next_action_text` | client | the next-action cursor; NULL = Actionless |
| `last_next_action_completion_at` | client | stamped when a focus session closes with the task non-done |
| `time_spent_minutes` | client | dead denormalized cache — no live write path since PR I retired the `transitionState` recompute; time-spent is derived from `SUM(time_logs)` at read time (issue #480); still round-trips until retired (#470 story 9) |
| `created_at` | client, server default when omitted | offline captures keep their true capture time |
| `updated_at` | client | the server never stamps it |
| `user_id` | **server** | derived from the JWT; any client-sent value is ignored by design |
| `location_id` | unused | no DAO writes it today |

The payloads arrive shaped by PowerSync/Drift: booleans as SQLite integers (`0`/`1`), timestamps possibly in Drift's space-before-offset format (`2026-04-30T00:00:00.000 +05:30`). The schemas must accept both — a `422` dead-letters the entry (window 3 above): the payload survives for diagnosis, but the write still never reaches the server.

The standing regression tripwire is `backend/tests/test_todos.py::test_connector_shaped_payload_roundtrips_client_state`, which POSTs a payload shaped exactly like a connector PUT and asserts every client-owned value persists. When adding a column to the Drift `Todos` table, add it to both schemas and to that test — or record it here as server-owned.

## The focus-session upload contract

`focus_sessions`, `focus_session_tasks`, `focus_session_dispositions`, and `time_logs` replicate like every other bucket, so their local writes go through the same upload path: `uploadData()` routes them to `POST`/`PATCH`/`DELETE` routes in `backend/app/todos/focus_session_routes.py`. The contract mirrors the `todos` one:

- **Every column is client-owned except `user_id`**, which is server-derived from the JWT on all four tables. The denormalized `user_id` the client sends (it exists locally for PowerSync bucket filtering, Alembic 0025 / 0027) is deliberately absent from the Pydantic schemas and therefore ignored, never trusted.
- **Create dedupes on the client `id`** per the create-dedupe contract above: a same-user replay upserts the submitted client-owned columns and converges (`2xx`); a cross-user id collision is a `409`. For `focus_session_tasks` and `focus_session_dispositions` the `(focus_session_id, task_id)` relation is a second dedupe key (same-id/different-relation `409`).
- **`focus_session_dispositions` is the durable home for off-Plan Dispositions** (ADR-0016): a Plan member's Disposition lives on `focus_session_tasks.disposition`, but an off-Plan engaged Outcome has no `focus_session_tasks` row (the Plan never auto-grows — ADR-0002), so its `rollover | leave | maybe` Disposition is uploaded here instead, keyed `(focus_session_id, task_id)`. Its only mutable field is `disposition`; the client re-records it with a deterministic `id` under `INSERT OR REPLACE`, which reaches the backend as a **PUT**, so the create route upserts `disposition` on replay (ADR-0015) — a changed value converges instead of being dropped (a direct PATCH converges too).
- **Parent/ownership checks are route-level `404`s** (session and task must belong to the JWT user) — a Postgres FK violation would be a `500`, which PowerSync retries forever.
- **`disposition` is validated to `rollover | leave | maybe` at the schema** on both `focus_session_tasks` and `focus_session_dispositions`, so garbage `422`s (fatal-skip) instead of tripping the DB CHECK constraint (`500` → infinite retry). Explicit `null` on NOT NULL columns (`position`, `started_at`, `task_id`) is likewise a `422`.
- **`DELETE /focus_sessions/{id}` clears its children itself** — child `focus_session_tasks` and `focus_session_dispositions` rows are deleted and `time_logs.focus_session_id` is detached (SET NULL semantics; time logs are the user's time data and are never deleted) — because none of those FKs has `ON DELETE CASCADE`.

The regression suite is `backend/tests/test_focus_sessions.py`; `test_full_session_upload_replays_in_queue_order` replays the exact CRUD sequence a synced client queues for plan → focus → review and asserts no step `4xx`s (the true queue semantics are engine behaviour with no automated harness, per the note above).

## The Capture-split upload contract

`captures`, `capture_outcomes`, and `capture_tags` (issue #184, ADR-0006) replicate like every other bucket and upload through `POST`/`PATCH`/`DELETE` routes in `backend/app/todos/capture_routes.py`. The contract mirrors the `todos` and focus-session ones:

- **Every column is client-owned except `user_id`**, which is server-derived from the JWT on all three tables. The denormalized `user_id` the client sends (it exists locally for PowerSync bucket filtering, Alembic 0026) is deliberately absent from the Pydantic schemas and therefore ignored, never trusted.
- **`captures` is the Inbox surface:** `clarified_at IS NULL` = still in the Inbox. `clarified_at` is client-owned and nullable — an explicit `null` on PATCH is legal (it un-stamps, returning the Capture to the Inbox), so it is *not* rejected the way NOT NULL columns are; `title` (NOT NULL) is rejected on explicit null (`422`). `capture_source`, `notes`, `created_at`, `updated_at` round-trip like their `todos` counterparts.
- **The junctions carry a client-owned `id` (PowerSync row id, `gen_random_uuid()` server default) plus their domain key.** `capture_outcomes` is keyed `(capture_id, outcome_id)` and carries a client-owned `created_at` provenance timestamp; `capture_tags` is keyed `(capture_id, tag_id)` and has no mutable fields (its connector PATCH is a no-op, like `todo_tags`).
- **Create dedupes on the client `id`** per the create-dedupe contract above: a same-user replay upserts the submitted client-owned columns and converges (`2xx`); a cross-user id collision is a `409`. The junctions add their domain pair as a second dedupe key (same-id/different-relation `409`).
- **Parent/ownership checks are route-level `404`s** — a `capture_outcomes` link requires both the Capture and the Outcome (todo) to belong to the JWT user; a `capture_tags` link requires the Capture and the Tag. A Postgres FK violation would be a `500`, which PowerSync retries forever.
- **`DELETE /captures/{id}` clears its children itself** — `capture_outcomes` and `capture_tags` rows for that capture are deleted first, because the connector delete path must not depend on `ON DELETE CASCADE` firing on Postgres (an FK violation would `500` and wedge the queue).

Column ownership — every column is client-owned except `user_id` (server-derived from the JWT), on all three tables:

| Table | Client-owned columns | Server-owned |
|---|---|---|
| `captures` | `id`, `title`, `notes`, `capture_source`, `created_at`, `clarified_at`, `updated_at` | `user_id` |
| `capture_outcomes` | `id`, `capture_id`, `outcome_id`, `created_at` | `user_id` |
| `capture_tags` | `id`, `capture_id`, `tag_id` | `user_id` |

The standing tripwires are in `backend/tests/test_captures.py` — connector-shaped roundtrip tests per table (alongside `test_connector_shaped_payload_roundtrips_client_state` for `todos`) plus junction `user_id`-denormalization and ownership-`404` tests. On the client, `app/test/services/backend_connector_test.dart` pins the upload routing, and `app/test/database/capture_view_notify_test.dart` pins the ADR-0010 view-notify invariant for the Capture views. When adding a column to a Drift Capture table, add it to the matching Create/Update/Out schemas and to the roundtrip test — or record it here as server-owned.
