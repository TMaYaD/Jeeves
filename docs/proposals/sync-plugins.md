# Proposal: Sync plugins

**Status:** Draft

## Problem

The op log over the minimal sync server is the only way a device syncs ([ADR-0026](../adr/0026-minimal-sync-server.md)). It answers the multi-user, end-to-end-encrypted case well. It answers a smaller case poorly: one person, a handful of their own devices, high trust, and a wish to see their system as plain files they own. That person should not have to run a server, and a server is not the only medium their data can travel through.

The direction: **the device database is the source of truth on every device, and sync is a plugin.** A plugin carries changes between this device and somewhere else. It never decides what a field's value is — the app does, with the merge strategies it already has ([SYNC.md](../SYNC.md), [ADR-0030](../adr/0030-merge-strategies-must-be-join-semilattices.md)).

This proposal fixes the interface between the app and a plugin. It does not build any plugin.

## The split

Today one component, the op-log client, owns two different things: **merge state** (the reduced value and winning clock of every field) and **transport** (the op log, signing, the outbox, cursors, quarantine). The interface separates them.

**The sync host — owned by the app.** The per-field merge state (`ReducedFields`, `FieldClocks`, `RowTombstones`), the reducer that merges into it under the strategy registry, the projector that materialises it into the domain store, and the reconciler that takes convergence decisions after a projection. All of these are already collection-generic; none of them needs to know where a change came from.

**A plugin — owned by its backend.** Everything about the medium: its wire format, its identity and trust model, its cursor, its durability evidence, its failure modes.

The merge tables are keyed by `(collection, entity_id, field)` with no Workspace or transport column, so the move is a change of ownership in code, not a data migration: the tables stay where they are, in the existing sync store, and the op-log transport tables stay beside them.

## The interface

```dart
/// One field-grain change: a CapturedOp with clocks.
class Change {
  final String collection;
  final String entityId;
  final Map<String, ClockedValue> fields;   // field → (value, hlc)
  final Hlc? tombstone;                      // a deletion is a clocked value, never absence
}

/// What the app gives a plugin.
abstract interface class SyncHost {
  /// Merge remote changes, project, reconcile, and forward them to every
  /// other active plugin. Idempotent: a change already merged is a no-op.
  Future<void> applyRemote(String sourcePluginId, List<Change> changes);

  /// Current merged state, for a plugin's first upload or full rewrite.
  Stream<Change> snapshot();

  /// A fresh clock, for a plugin whose medium carries none.
  Hlc mintClock();
}

/// What a plugin implements.
abstract interface class SyncPlugin {
  String get id;
  Future<void> start(SyncHost host);
  Future<void> stop();

  /// Changes after [cursor] in the host's change sequence — local writes and
  /// other plugins' changes alike. The plugin persists the cursor it has
  /// durably handed off; on start, after a crash, it resumes from there.
  Future<int> deliver(int cursor, List<SequencedChange> changes);

  Stream<PluginHealth> get health;
}
```

The outbound half already exists: `DomainOpCapture` emits one coalesced `(collection, entity_id, fields | tombstone)` per entity per committed transaction, with no Sync type in its signature. The host stamps clocks onto it and appends it to a **durable change sequence** in the same commit that records it in merge state. Nothing is ever pushed into a plugin that it could lose: each plugin reads the sequence from its own cursor, so a crash between commit and hand-off replays rather than drops, and forwarding between plugins is the same read. The inbound half is the reducer's job generalised from `OpPayload` to `Change`.

**Clocks are the host's, not the medium's.** Every merged field carries an HLC. A plugin whose medium carries clocks (the op log) passes them through. A plugin whose medium does not — a page someone edited by hand — mints one at the moment it observes the edit. Ties break on a stable device identity; the op-log plugin's member id is one, and the host needs one that exists without enrolment.

**Several plugins, one at first.** Merge is a join semilattice, so a change that comes back to the device it left from merges as a no-op. Forwarding every applied change to every other plugin is therefore safe without echo suppression, and the interface allows any number of active plugins. Recommended: the first release activates one at a time, so enabling more later is a settings change, not a redesign.

## Candidate plugins

**Op-log server.** Today's backend, re-seated behind the interface. Envelopes, signatures, per-author chains, encryption, enrolment, key wraps and the control plane stay inside it, unchanged. It is the only candidate that serves several Users and a Service holding a Workspace grant.

**Op-log folder.** The same signed op log, written to a folder instead of posted to a server. Each device appends to its own segment files — `ops/{member_id}/000001.log`, rolled at a size or age bound, sealed once rolled — and reads every other member's. Every file has exactly one writer, so a file syncer never sees a conflict; the per-author hash chains still detect a truncated or rolled-back file; the cursor is `(member, segment, byte offset)` per author. Records are length-prefixed and checksummed so a partially-transferred tail is ignored rather than misread. Needs no server, keeps every integrity property of the op log, and is opaque to the user.

**Vault.** A folder of Markdown pages that *is* the user's GTD system on disk, mirroring the paper practice of one sheet per thing:

- `Outcomes/<slug>.md` — one page per Outcome. Frontmatter carries its id, Intent, due date, Area and Labels; the body carries its notes and its Actions as a checklist.
- `Sessions/<date>-<session-id>.md` — one sheet per FocusSession, so two sittings on one day never collide: the Plan as a checklist of links to Outcome pages, the TimeLogs recorded against it, and the Dispositions given at Review. The sheet a person writes when they sit down at the desk and files away when they leave.
- `Inbox/<capture-id>.md` — one page per Capture. The body is the captured text and is never rewritten ([ADR-0023](../adr/0023-clarification-never-rewrites-the-capture.md)); frontmatter carries what does change — `clarified_at` and the tag hints — and merges like any other field.

Pages are readable, greppable and editable by any tool; an edit made outside the app is observed, diffed field by field and applied as a change. Each device keeps a private, unsynced copy of the last version of each page it has seen. When the medium surfaces a concurrent version, the plugin has base, local and remote, and merges three-way per field; only the same field changed on both sides is a real conflict, and the host's strategy settles it. Deletion is a tombstone in the page, never a missing file, because a missing file is indistinguishable from one that has not arrived. The vault carries no signatures and no encryption; its trust model is whoever can read the folder.

**Roundelay.** A plugin for the external roundelay sync service. What the interface owes it is the same as for any other: changes in, changes out, health. Its protocol, identity model and conflict semantics are not documented in this repository and are an open question below.

## Consequences

- **The domain store is no longer disposable on its own.** [ADR-0040](../adr/0040-local-durability-is-independent-of-sync.md) rests on the op log being able to reproject it. With a vault as the only plugin there is no op log; the host's merge state becomes the device's durable record, and the domain store remains a projection of it.
- **Un-enrolled devices start keeping clocks.** Today a device that never enrols authors nothing ([ADR-0034](../adr/0034-sync-starts-at-enrolment.md)). Under the host, every local write is clocked so that whichever plugin is attached later can carry it. Writes made before the host existed are not in merge state, so the host goes live only after a one-time, restart-safe **seeding pass** walks the domain store into merge state behind a completion marker — the job the op-log initial upload does today. Only then is `snapshot()` complete.
- **Export is unaffected** ([ADR-0047](../adr/0047-export-is-the-op-log-wire-encoding-and-import-detects-it-silently.md)): it reads the host's merged state, which every plugin feeds.
- **Preference keys still carry their key** ([ADR-0033](../adr/0033-user-preferences-ops-carry-their-key.md)): strategy selection stays a function of the change alone, whichever plugin delivered it.

## Open questions

1. **Roundelay.** Its protocol, how it identifies devices and Users, whether it carries field clocks or whole records, and whether it merges server-side.
2. **Vault field clocks.** Where a page keeps the clocks that order its fields — a frontmatter key, or a sidecar under a hidden folder — and how much of that a person editing the page is expected to see.
3. **Workspace.** Whether partitioning ([ADR-0027](../adr/0027-workspace-as-partition-unit.md)) stays a host concept every plugin respects, or becomes the op-log plugin's concern alone.
4. **Health.** How several plugins' health folds into the single drawer indicator and the sync-health screen.
5. **Device identity.** What the host uses as the HLC tie-breaker before, or without, enrolment.
6. **Cross-store commit.** Merge state and the change sequence live in the sync store, a different file from the domain store, so a domain write and its clocked record cannot share one transaction. How a crash between the two commits is detected and repaired — for instance re-deriving changes from domain rows newer than the last recorded sequence — has to be settled before the host is built.
