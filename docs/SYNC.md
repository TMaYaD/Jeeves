# Sync & Conflict Resolution

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

Jeeves is offline-first. Local writes go to the embedded SQLite store immediately, and are replicated between devices by the **op log** — signed ops over the minimal sync server — as soon as the device is enrolled and reachable ([ADR-0026](./adr/0026-minimal-sync-server.md), [ADR-0034](./adr/0034-sync-starts-at-enrolment.md)). Replication runs through the **sync host**, which owns the merge state; the op log and the **vault** are plugins behind it, and one plugin runs at a time (#914); there is one replication engine on the device, and no second (#595). Habit tables have no codec: not on the wire or in the export.

This document is about **merge**: how two devices that wrote concurrently end up agreeing, with the focus on the `user_preferences` synced key-value store, where blanket last-write-wins is sometimes wrong.

For where this sits in the system see [ARCHITECTURE.md § The sync spine](./ARCHITECTURE.md#the-sync-spine); for the vocabulary, [CONTEXT.md § Sync](../CONTEXT.md#sync).

## What "conflict" means here

There is no upload/download asymmetry to reason about. An authored op is durable in the outbox from the moment it is signed, and reduced state is a join semilattice ([ADR-0030](./adr/0030-merge-strategies-must-be-join-semilattices.md)) — so a write is never lost to a race with a pull, and a row is never wiped because a server snapshot omitted it. Every device reduces every op it receives, in whatever order it receives them, and lands on the same state.

What remains is one question per field: **two writes to the same field of the same entity, neither aware of the other — which value stands?**

## The tombstone invariant

Deletion in `user_preferences` is modelled as a **tombstone** — a present row with `value = NULL` — never a physical row removal (`UserPreferencesDao.set(userId, key, null)`). The invariant is what makes the merge rules unambiguous:

> A genuinely **absent** value can only mean "no device has ever written this key." A real cross-device **delete** arrives as a present tombstone, not an absence.

So a key that reads as absent is a key nobody has set, and "absent → keep whatever is local" can never swallow a legitimate delete. A delete is a value, not a gap.

The same shape holds at the entity level: the reducer tombstones an entity rather than forgetting it, so a rebuild of the domain read model from the log deletes a row it has to rather than silently resurrecting it (`sync/domain_rebuild.dart`).

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
- **`maxTimestampValue`.** For snooze "until" floors. Among two live writes the later *value* (parsed as a timestamp) wins, so a stale write can never regress an active snooze and re-fire a notification the user silenced. A **tombstone (clear/un-snooze) is arbitrated against a live value by LWW** — a clear silences the snooze, but a later re-snooze survives a stale clear. Any key ending in `snoozed_until` is classified here automatically.
- **`minTimestampValue`.** For the Sprint end (`sprints.ended_at`), the mirror of `maxTimestampValue`: any end beats a still-open Sprint, and of two ends the **earlier** wins, whichever device wrote last. An end can only move earlier and is never cleared. Chosen from the change's collection and field, never from stored state.
- **`setMerge`.** Union of the two JSON-list values so concurrent additions on two devices both survive. **No production key uses this today**; it is provisioned so a new list/set-shaped key (filter selections, pinned items) cannot ship under naive LWW that would drop concurrent additions. New set keys **must** be registered as `setMerge` before use; an ordered, capped list (recent searches) is the explicit `lww` case, because a union would sort it, grow it past the cap and resurrect removed entries.

Every strategy owes ADR-0030's obligations: merge must be commutative, associative and idempotent. A strategy that is not is a divergence bug, not a preference.

### The default is safe for any future key

An unregistered key resolves as `lww`, which never *loses* a write: it selects the newer of the two by HLC and nothing else. That includes a tombstone, which the reducer treats as an ordinary value (see the matrix below) — so a later clear does win, and the key reads as absent afterwards. What LWW does not do is remove the row or discard the fresher of two writes: a key needs explicit registration only when *choosing the newer write* would be wrong (snooze floors, sets).

### Explicit registration

`preferenceConflictRegistry` is an exact-match `key → strategy` map consulted **before** the `snoozed_until` suffix rule and before the default, so an entry there always wins. Registering `lww` explicitly is redundant at runtime — the key would fall through to it anyway — but it records that the strategy was chosen and reviewed rather than inherited, which is the bar for a key whose arbitration a reader would otherwise have to re-derive. Keys registered explicitly are marked in the matrix below.

### Strategy selection is per op

The strategy is selected from the op alone. A `user_preferences` op that carries `value` carries its `key` too, and the reducer refuses one that does not, under `preference_value_without_key` — a logged-but-refused quarantine, not a decode failure. A change whose collection belongs to another Workspace is refused the same way, under `collection_outside_workspace`, and pinned by `user_preferences_change_in_the_default_workspace_log_is_refused` and `default_workspace_collection_in_the_preferences_log_is_refused`. **Nothing stored is read to pick the strategy**, so two devices cannot arbitrate the same pair of writes under different lattices depending on which of them had already learned the key ([ADR-0033](./adr/0033-user-preferences-ops-carry-their-key.md)). `SyncClient.capture` runs the same guard before authoring, so the shape cannot be signed into an outbox either. The refusal is pinned by `user_preferences_value_without_key_is_refused` (`spec/sync/reducer_v1_vectors.json`).

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
| `focus_settings_sprint_duration_minutes`, `…_break_duration_minutes`, `…_long_break_duration_minutes`, `…_sprints_before_long_break` | int | `lww` | Scalar setting; latest intent wins |
| `focus_session_planning_settings_time_hour`, `…_time_minute`, `…_notification_enabled`, `…_banner_enabled`, `…_default_snooze_duration`, `…_default_time_estimate` | int / bool | `lww` | Scalar settings |
| `planning_banner_dismissed_date`, `planning_notification_skipped_date` | date | `lww` | Latest-intent scalar, not a set |
| `shutdown_ritual_completed_date`, `shutdown_banner_dismissed_date`, `shutdown_notification_skipped_date` | date | `lww` | Latest completion / suppression wins |
| `periodic_review_last_completed_at`, `periodic_review_open_since` | datetime | `lww` | Completion and opening timestamps |
| `focus_session_planning_last_session_available_minutes` | int (minutes) | `lww` | Latest session's planned time wins; pre-fills the next Daily Planning Time step |
| `periodic_review_banner_dismissed_date`, `periodic_review_banner_enabled`, `periodic_review_notification_enabled`, `periodic_review_notification_hour`, `periodic_review_notification_minute`, `periodic_review_notification_skipped_date` | date / bool / int | `lww` | Scalar settings / suppression |
| `periodic_review_nudge_content_firing_edge` | datetime | `lww` | Latest firing edge wins |
| `clarify_mode` | string enum (`oneToOne` / `nToM`) | `lww` *(registered explicitly)* | Scalar mode selection; both modes read the same many-to-many storage, so either winner leaves every Capture and link valid |
| `shutdown_settings_time_hour`, `shutdown_settings_time_minute`, `shutdown_settings_notification_enabled`, `shutdown_settings_banner_enabled` | int / bool | `lww` | Scalar Evening Shutdown settings |
| `jeeves_recent_searches` | JSON list of strings | `lww` *(registered explicitly)* | Ordered, capped list with removals; the latest whole list wins |
| `onboarding_seen` | bool | `lww` | Only ever written as `true`; also kept on the device for the cold-start read |
| `bypass_threshold` | int | `lww` *(registered explicitly)* | Scalar setting; the latest choice on any device wins |
| `device_name.<device id>` | string | `lww` | A Device's name; two renames resolve to the later one |
| `planning_notification_snoozed_until`, `shutdown_notification_snoozed_until`, `periodic_review_notification_snoozed_until` | datetime | `maxTimestampValue` | Snooze floor must never regress; un-snooze is a tombstone |
| *(none today)* | list/set | `setMerge` | Provisioned for future filter/pin selections |

**Snooze arbitration departs from the blanket LWW default**; the `maxTimestampValue` bullet above states the rule.

### Sprints

A Sprint (`sprints`: Action, start, end, set length) is recorded locally first and replicated like a TimeLog. Only `ended_at` is arbitrated; every other field is LWW.

| Situation | Result |
|---|---|
| One device wrote the Sprint | It stands. |
| One device ended it, another left it open | The end stands. |
| Two devices ended it at different instants | The earlier end stands, on both. |
| Left open, and the user has a later Sprint | Reads as ending 1 ms before the later one starts. Derived when read (`sprintRecordsWithEffectiveEnds`), never written, so no device authors a convergence write. |

A stored end later than the next Sprint's start (closed late on an offline device) stays as recorded. A Sprint ends in the same transaction as the TimeLog it ran under.

Bypassed Outcomes add three collections, `focus_session_planning_bypasses`, `focus_session_reschedules` (one row per session and Outcome, replaced by a later edit) and `outcome_bypass_decisions` (append-only), each registered in `collection_codecs.dart` and carried by the initial upload. Jeeves works without them leaving the device: they are ordinary local rows first.

`focus_session_tasks.pinned_start_at` is the start time the user set on a Plan entry; it merges last-write-wins per field like `disposition`, and clearing it writes a null. So do `batch_id` and `batch_suggestion_declined_at`.

`places` and `time_windows` merge last-write-wins per field and do not fold; Tags fold by name.

### Device names

A Device's name is ordinary synced data: one `user_preferences` key per device id, `device_name.<device id>`, holding the name as a JSON string. A Device writes it under its own device node id and, once enrolled, under its member id as well, so a peer can resolve whichever of the two ids it sees on a change.

A name is shown only for this device, or for a Device whose Grant in the preferences Workspace has been applied — never for an id no applied Grant vouches for, and never as the raw id.

## Derived identity, and why merge does not need to care about it

Two collections have a domain key that is not their `id` column: `focus_session_tasks` (the `(session, task)` pair) and `user_preferences` (the `(workspace, key)` pair). Their local DAO writes mint a row id of their own, so two devices creating the same logical row would otherwise fork into two entities that never merge.

They do not, because the id is **derived**: `focusSessionTaskIdFor(sessionId, taskId)` and `preferenceEntityId(workspace, key)` (`app/lib/sync/ids.dart`). Every device names the same entity, so the ordinary field-grain merge above applies unchanged, and the projector realigns the local row's `id` onto the derivation when it writes reduced state back (`app/lib/sync/domain_projector.dart`). Junction rows in `todo_tags`, `capture_outcomes` and `capture_tags` follow the same rule through their `*IdFor` helpers.

## Where merge state lives

Merge state — the reduced value and winning clock of every field — belongs to the
**sync host**, not to the op-log client. The host merges a `Change` (a clocked,
field-grain write) under the strategy registry; the op-log reducer only checks the
op-level guards and converts an op to a `Change`. A device with no enrolment still
clocks and merges its own writes, under a random device node id; once enrolled, its
member id takes over as the tie-break so the wire is unchanged. Clocks stamped under
the device node id are never ops, so the enrolment upload does not skip them, a
rebuild from the log carries them across, and an account's later sign-in authors
those made since its upload completed — creates, edits and deletes, not preferences. A change stamped under a member id that is then never authored — a write made before session restore answered "signed out" — has its clock handed back to the device node id, so the same three paths cover it. A change merged under a member id is kept in the sync store until the op-log bridge has authored it or handed it back, so a process killed in between authors it on the next launch. See [sync-plugins](proposals/sync-plugins.md).

Rows that predate the host are seeded into merge state once per device, before any
plugin can attach, so `snapshot()` holds the whole local dataset. Seeding inserts
only fields merge state holds no value or clock for, each at the floor clock
`Hlc(0, 0, <device node id>)`, so any real write from any time beats a seeded value.
It writes no domain row, tombstone or change.

Merge state reaches the domain store through the projector, which gives up the
store's writer between batches — a whole-store re-projection (after a schema upgrade,
or a rebuild from the log) never holds a user's edit back for its length. That walk,
and only that walk, leaves an entity whose local change is still in the outbox.
Remote changes are projected on arrival, or by the next pull. `DomainProjector.project`
(`sync/domain_projector.dart`) gives the reason for each.
## The vault: a folder of Markdown pages

The vault is the first plugin behind the host ([sync-plugins](proposals/sync-plugins.md)). It carries the device's merged state to a folder of pages a person can read and edit, and brings back their changes. It needs no account and no server: a file syncer of the person's choosing carries the folder between devices.

**It is a carrier, like any plugin.** It turns a page into changes and writes the host's merged state back as a page. It never chooses between two values and never writes a value the host did not give it; the one thing it authors is a clock for a hand edit, minted with `SyncHost.mintClock()`.

**What is on a page.** One page per Outcome (`Outcomes/`), one sheet per FocusSession (`Sessions/`), one per Capture (`Inbox/`). A sheet's name carries the session's UTC date and its id, so sittings never collide. A page's identity is the `id` in its frontmatter, never its path. **What a person can edit is what a page shows**: an Outcome's title, intent, due date and notes, its Actions as a checklist, a Capture's clarification stamp, and the Labels and Area the page shows. The rest of a page is the app's to write.

**A page is a pure function of merged state**: the same state always renders the same bytes, in the same order and in UTC, so two devices in the same state write the same file and a file syncer never sees a conflict between them. The readable part is frontmatter, notes, and a final `## Actions` heading that is always written; everything between the frontmatter and that heading is the notes, byte for byte.

**The clocks live in one machine-written block at the end of the page**, inside an HTML comment ([ADR-0051](./adr/0051-vault-pages-keep-field-clocks-in-one-end-block.md)). It carries each field's clock and a digest of the value it stamped; a carried value that no longer matches its digest is not taken. A person who deletes or mangles it loses nothing the device has already seen: the plugin falls back to the base copy's block, so the hand edit is still seen. A device with no base copy of that page (a fresh install) keeps the file but cannot import the edit.

**Reading a page** compares it with this device's **base copy** — the last version of that page it saw, private to the device and never synced (`app/lib/sync/vault/vault_plugin.dart`). A value that matches its digest is what some device wrote at that clock and passes through with it; a value that does not match is a hand edit and gets a fresh clock. A stale copy carries old clocks, so the host ignores it. A page is read in two batches — the values that carry a clock reach the host first, so a hand edit's clock is later than every clock the page carries.

**Deletion is a tombstone in the page, never a missing file** — a missing file may simply not have arrived. A deleted Outcome keeps its page and gains a `deleted` date in its frontmatter; a deleted Action's line disappears and its tombstone stays in the block. A deleted page is frozen: removing the `deleted` line does not bring the Outcome back.

**Hand edits bypass the app's own write rules.** A hand edit writes the fields the page shows and no more; it does not run the DAOs, so it stamps no `last_clarified_at` and the app's re-clarification offers still apply. An entity a hand edit creates gets an id derived from what was typed, so two devices that read the same edit create one entity (`app/lib/sync/ids.dart`).

**What the vault does not carry:** preferences, places and time windows, and Tags no page names — an Area with no Outcomes has no page. They stay on the device.

**Where it fails.** A page that cannot be read or parsed is left alone and counted; a folder that cannot be listed is reported, and the other folders are still read. A page the host will not take is left alone and counted too: its content is in the folder and nowhere else, so it is kept — never removed, never written over — and the next pass takes it again. A page the folder will not write is owed a write-back that the next pass makes, and the pages that owe one are counted in the health. A delivery the folder could not read is not acknowledged, so the host sends it again. All of it shows in `VaultHealth` and the log, not yet in the drawer indicator (#916).

**How the folder is reached.** One port (`VaultFolder`, `app/lib/sync/vault/vault_folder.dart`): a plain directory over `dart:io`, Android over the shared `jeeves/folder` document-tree channel, which carries the three operations the vault needs (`readAll`, `writeAtomically`, `remove`). The document tree has no atomic replace, so a page is written through a temporary document and a rename, with the old page moved aside until the new one is in place. Over a plain directory a page that would leave the folder — through a symbolic link — is refused.

**Session sheets are read only.** A hand edit to a sheet is not applied, and the next write restores it: what editing a Plan, a TimeLog or a Disposition by hand should mean is not settled.

## Protocol surface

Five things are wire contract rather than implementation detail. Changing any of
them changes what a peer sees, so each is pinned by a golden vector.

**Value encodings.** A Drift `dateTime` column encodes as an ISO-8601 UTC instant
truncated — never rounded — to exactly three fractional digits with a trailing
`Z`. TEXT timestamp columns pass through byte-for-byte as opaque strings. Text,
int, bool and null pass through as JSON natives. A column that changes its Dart
type changes its encoding, and that is a protocol change.

**Entity ids.** Normal collections keep client-random UUIDs. Two kinds are
deterministic: `user_preferences` derives its id from
`(workspace, key)`, and junctions derive theirs from their pair. The rule is in
`app/lib/sync/ids.dart`, and the Tag collection is named there as one
that must *not* derive — a Tag's op-log identity is its random `id`, while
`(name, type)` is only its user-facing identity, which is why duplicates are
representable and folded, not prevented
([ADR-0043](adr/0043-tag-duplicates-are-representable-and-folded.md)).

**One stored value for Label.** Label is `type='context'`; the reconciler
retypes any `'label'` Tag to it before folding.

**One Project per Outcome.** Each Outcome–Project link is its own entity, so two
Devices assigning different Projects while apart leave two live links that
last-write-wins never compares. The one-Project pass keeps the link with
the greatest clock (ties: smaller tag id) and unassigns the rest by tombstone;
the winner is not re-asserted, so a later assignment elsewhere still beats it.

**No implicit cascades.** The log has no foreign keys, so nothing downstream
infers that deleting a parent removes its children. Every deletion enumerates its
own cascade set at capture time. A new child table means every delete path that
should reach it has to be updated by hand; nothing will fail loudly if it is not.

**A removal is a tombstone.** The log has no row-level delete either, so a
junction row that is simply absent is a row only this device dropped: the peer
keeps it, and the next pull puts it back. Every path that removes a link
authors that junction's tombstone, in the same transaction as the deletion — and
only for the links it actually held. A removal of a link this device never had
authors nothing: its tombstone would drop an assignment a peer had just made.

`SyncHealth.clean` is a derived getter over queue depth, unresolved alarms and
quarantine count — never a stored status, so a wedged device cannot report itself
healthy by writing it down.

## Refusals

Two things the sync layer will not do, and what happens instead.

**Encryption never turns itself on.** It is a per-Workspace ceremony an owner runs
with the passphrase, never a deploy and never a migration. A Workspace that has
not run it stores plaintext content ops, and that is a legible state rather than
a failure — the epoch floor records when it changed, so no receiver has to guess
which regime an op was written under.

**A Workspace with a live-granted Service cannot rotate.** A Service holds no
per-User key-exchange subkey, so there is nothing to wrap the new epoch key to.
The ceremony refuses before authoring anything rather than publishing a rotation
that would strand the Service mid-stream. Revoking the Service is the way
through.

## Alarm resolutions

| Kind | Class | Resolution | What the decision does on the device |
|---|---|---|---|
| `author_chain_gap` | actionable | **Take upstream** (one-time) | The held changes of that device reach this device's own records, and their rows are stamped. The rows stay eligible for normal chain release, so if the missing change arrives later the log heals and the apply is a no-op. The alarm is settled only once the change has reached the records — a failure there leaves the accusation standing and the decision on offer, and the work is kept until it has: a later pull puts it on screen even after the chain release has re-admitted the row. `op_log` is not touched. Also settles that device's `author_chain_fork`. |
| `own_writes_rollback` (server lost writes it had acknowledged) | actionable | **Keep ours** | Marks this device's own outbox rows from the position the server expects as unsent, so the next flush re-sends the same signed bytes. Nothing is re-numbered or re-signed. The alarm is *decided* at once and *resolved* when the re-send is acknowledged — every row from that position onwards sent. An answer about an accusation that has changed since it was asked is refused: nothing is queued and the new accusation stays open. |
| `own_writes_rollback` (server holds a position this device never wrote) | actionable | none — #974 | Needs a new device key or re-enrolment. |
| `own_writes_divergence` | reported | **Keep ours** (no upload) | Ours is already on the log. Records that the other copy is refused for good. |
| `author_chain_fork` | reported | **Reject permanently** | Stamps every continuation proven against the head, including every claimant at the position the accusation names. If no undecided held change of that device remains, the `author_chain_gap` alarm they were holding open resolves too. |
| `signature_invalid`, `aead_failure`, `plaintext_at_encrypted_epoch`, `no_live_grant`, `prev_author_hash_mismatch`, `author_chain_rewrite`, `duplicate_op_id_divergence` | reported | **Reject permanently** | Stamps the refused bytes as final. No state changes; the bytes stay. |
| Refused change with no alarm kind (codec and certificate reasons) | reported | **Reject permanently**, per row | Same, on that one row. |
| `own_write_refused_permanently` | actionable | none — #647 | Needs the outbox to drain past an op that can never be posted. |
| `epoch_key_set_unpublishable` | actionable | none — #661 | Needs an in-app way to rotate keys again. |
| `author_stream_reordered`, `stale_prefix_served`, `control_chain_fork`, `author_chain_slot_collision` | reported | none — #656, #657, #658, #659 | The app already settled these; they should resolve themselves. |
| `prune_attestation_divergence` | reported | none — #660 | No mechanism exists to contest a compactor's attestation. |
| Unknown code, self-healing refusal | — | none | Listed (unknown) or hidden (self-healing), as the classification says. |

Decisions are recorded; bytes are kept.

## What is asserted, and where

- **Merge semantics**: `app/test/sync/merge_strategy_test.dart`, `app/test/services/user_preferences_conflict_test.dart` and the golden vectors in `spec/sync/reducer_v1_vectors.json` (shared with the server's Python reducer, so divergence is caught).
- **Sprints**: `app/test/sync/host/sprint_record_convergence_test.dart` (two devices through the relay plugin), the lattice cases in `merge_strategy_test.dart` and `app/test/database/sprint_dao_test.dart` (derived end, TimeLog close sites).
- **Device names**: `app/test/sync/device_names_test.dart` (key, normaliser, ensure, rename) and `app/test/sync/host/device_name_convergence_test.dart` (two devices through the relay plugin).
- **Convergence end to end**: `app/test/sync/convergence_test.dart` and `full_day_convergence_test.dart` run two simulated devices through enrol → write → sign → append → pull → verify → reduce and assert byte-identical state.
- **Projection**: `app/test/sync/projector_view_notify_test.dart` (a reduced-in row reaches the watching queries) and `domain_rebuild_test.dart` (a fresh domain store rebuilt from the log, tombstones included).
- **One refusal, one row**: `app/test/sync/quarantine_once_test.dart` — two pulls fetching the same refused op file it once; two ops refused at one seq stay two rows.
- **Refused ops heal**: `app/test/sync/unchained_refusal_release_test.dart` — a change refused as `member_not_chained_to_root` is re-received once it knows the author's key, and a key Root never vouched for stays refused; `app/test/sync/control_chain_break_release_test.dart` — a control op refused as `control_chain_break` applies once its predecessor does, one naming no real predecessor stays refused, one served below the op it names stays refused, and a device that lost its epoch key fetches it again.
- **A removal reaches the peer**: `app/test/sync/dao_capture_contract_test.dart` (the task detail's four removal paths drop it in the deletion's own transaction) and `app/test/sync/tag_convergence_test.dart` (a context, a person, the delegate set and the Project removed on one device are each gone on the other).
- **The vault**: `app/test/sync/vault/` — two devices sharing a folder (`vault_plugin_journey_test.dart`), the plugin's behaviour (`vault_plugin_behaviour_test.dart`), the page codec (`page_codec_test.dart`) and its upgrade path (`vault_migration_test.dart`); the app's own route is `app/test/integration/vault_sync_journey_test.dart`. Derived ids are pinned in `app/test/sync/ids_vectors_test.dart`.
