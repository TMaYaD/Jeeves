/// The client-owned sync store.
///
/// ADR-0026 requires the received log to be *the client's*, immutable evidence:
/// per-author chains only make server truncation and rollback detectable if the
/// client keeps what it received. So [OpLog] holds full envelope bytes, and
/// `chain_verifier.dart` reads them back to derive each author's verified head.
///
/// This database is deliberately separate from `lib/database/gtd_database.dart`
/// and shares nothing with it. The production app still runs on PowerSync until
/// the cutover in #553; wiring both paths together now would be exactly the
/// dual-write branching the Implementation stance forbids.
library;

import 'package:drift/drift.dart';

part 'sync_database.g.dart';

/// Every envelope this device has received, byte for byte, in arrival order.
///
/// The unique index over `(workspace, author, author_seq)` mirrors the server's
/// own per-author constraint, and it is deliberately a *constraint* rather than
/// a convenience: one slot of an author's chain holds one op, so a bug that
/// double-logs a position throws instead of quietly corrupting the evidence the
/// chain verdict is derived from. The `(workspace, author, op_id)` index is what
/// makes the divergent-duplicate check (F13) a lookup rather than a scan.
@TableIndex(
  name: 'op_log_author_chain',
  columns: {#workspaceId, #authorMemberId, #authorSeq},
  unique: true,
)
@TableIndex(name: 'op_log_author_op_id', columns: {#workspaceId, #authorMemberId, #opId})
@DataClassName('OpLogRow')
class OpLog extends Table {
  /// The server's transport cursor. Never causality, never a merge input.
  IntColumn get seq => integer()();
  TextColumn get workspaceId => text()();
  BlobColumn get envelope => blob()();
  TextColumn get opId => text()();
  TextColumn get authorMemberId => text()();
  IntColumn get authorSeq => integer()();
  DateTimeColumn get receivedAt => dateTime()();

  /// When the reducer applied this op. Null means "logged as chain evidence and
  /// never applied" — see [refusedReason]. Exactly one of the two is set.
  DateTimeColumn get appliedAt => dateTime().nullable()();

  /// The `SyncRejectionReason.code` of the reducer guard that refused this op.
  ///
  /// A signature-or-chain-valid envelope is logged even when a reducer guard
  /// then refuses its payload, because withholding it would make the author's
  /// *next* op look like a chain gap. Recording *which* guard fired is what
  /// keeps a later replay (#555) from re-evaluating a time-dependent rule like
  /// `hlc_in_the_future` hours later and reaching a different answer.
  TextColumn get refusedReason => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, seq};
}

/// Envelopes built and signed at capture time, waiting for a successful POST.
///
/// Signing at capture rather than at send is what makes `author_seq` and
/// `prev_author_hash` a real chain: the order the device authored in is the
/// order the chain records, whatever the network does afterwards. It is also
/// the offline queue — a failed POST leaves these rows untouched.
@DataClassName('OutboxRow')
class Outbox extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get workspaceId => text()();
  TextColumn get opId => text()();
  IntColumn get authorSeq => integer()();
  BlobColumn get envelope => blob()();
  DateTimeColumn get capturedAt => dateTime()();

  /// Set once the server has acknowledged the op (including as a duplicate).
  /// Acknowledged rows are kept rather than deleted: they are this device's
  /// record of what it *authored*, and comparing them against what the server
  /// later serves back is the whole own-writes divergence check.
  DateTimeColumn get sentAt => dateTime().nullable()();
}

/// This device's own position in its per-author chain, per workspace.
@DataClassName('AuthorStateRow')
class AuthorState extends Table {
  TextColumn get workspaceId => text()();
  TextColumn get memberId => text()();
  IntColumn get nextAuthorSeq => integer()();
  BlobColumn get lastEnvelopeHash => blob()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, memberId};
}

/// The pull cursor. Client-held: the server persists none (review F17).
@DataClassName('SyncCursorRow')
class SyncCursors extends Table {
  TextColumn get workspaceId => text()();
  IntColumn get lastSeq => integer()();

  /// When the last pull completed, independent of flush state — the
  /// `SyncHealth.lastSyncedAt` source. Deliberately not "last successful sync":
  /// a wedged outbox is reported through `pendingOpCount`, never by withholding
  /// a timestamp that would make a receiving device look unreachable.
  DateTimeColumn get lastSyncCompletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId};
}

/// Ops that failed a fail-closed rule: never applied, always surfaced.
///
/// [authorMemberId] and [authorSeq] are populated for chain refusals so the
/// release scan can look up the one row that could now be chain-valid — the op
/// at the author's head + 1 — instead of walking the table on every accepted op.
@TableIndex(
  name: 'quarantined_ops_author_chain',
  columns: {#workspaceId, #authorMemberId, #authorSeq},
)
@DataClassName('QuarantineRow')
class QuarantinedOps extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get workspaceId => text()();
  IntColumn get seq => integer().nullable()();
  TextColumn get reason => text()();
  TextColumn get detail => text()();
  BlobColumn get envelope => blob()();
  DateTimeColumn get detectedAt => dateTime()();

  /// The refused envelope's author, when its header parsed. Null for bytes so
  /// malformed that there was no author to record.
  TextColumn get authorMemberId => text().nullable()();
  IntColumn get authorSeq => integer().nullable()();

  /// When a quarantined op became chain-valid and was re-admitted.
  ///
  /// Rows are kept rather than deleted: a hostile reorder that healed is still
  /// something the user gets to inspect, and the timestamp is what separates
  /// "reordered and converged" from "withheld and still missing".
  DateTimeColumn get releasedAt => dateTime().nullable()();
}

/// What the server or an author stands accused of — the per-event vocabulary,
/// distinct from [QuarantinedOps]' per-op refusal reasons.
///
/// The two are not 1:1 in either direction. `own_writes_rollback` is detected on
/// a POST refusal and has no received envelope to quarantine at all; one chain
/// gap covers however many successors the gap refused. Rows are upserted by
/// `(workspaceId, kind, authorMemberId)` so a server re-serving the same evil on
/// every sync bumps [occurrenceCount] instead of flooding the table.
///
/// [resolvedAt] marks an accusation that no longer stands — a gap alarm whose
/// every refused row was later released. `SyncHealth.unresolvedAlarmCount`
/// counts the rows where it is null, which is why a heal has to clear it rather
/// than merely add a second row.
///
/// The unique index makes that upsert key a real constraint rather than a
/// convention `_raiseAlarm` happens to honour. It does not cover the
/// server-only alarms: SQLite reads distinct NULLs as distinct, so a null
/// [authorMemberId] is unconstrained and `_raiseAlarm`'s select-then-write stays
/// the mechanism for those. A sentinel author id would buy the constraint at the
/// cost of making "accused of nothing in particular" a member id, which is a
/// worse trade in a table whose whole content is an accusation about a member.
@TableIndex(
  name: 'integrity_alarms_key',
  columns: {#workspaceId, #kind, #authorMemberId},
  unique: true,
)
@DataClassName('IntegrityAlarmRow')
class IntegrityAlarms extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get workspaceId => text()();

  /// An `IntegrityAlarmKind.code` — see `chain_verifier.dart`.
  TextColumn get kind => text()();

  /// The author whose stream the alarm is about. Null when the accusation is
  /// against the server alone.
  TextColumn get authorMemberId => text().nullable()();
  TextColumn get detail => text()();

  /// The [QuarantinedOps] row this alarm was first raised for, when there was
  /// one. Null for alarms with no received envelope behind them.
  IntColumn get quarantineOpRowId => integer().nullable()();
  IntColumn get occurrenceCount => integer()();
  DateTimeColumn get firstDetectedAt => dateTime()();
  DateTimeColumn get lastDetectedAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
}

/// The reduced value of one field of one entity. Visibility is decided at read
/// time against [RowTombstones]; nothing here is ever deleted by a tombstone.
@DataClassName('ReducedFieldRow')
class ReducedFields extends Table {
  TextColumn get collection => text()();
  TextColumn get entityId => text()();
  TextColumn get field => text()();
  TextColumn get valueJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {collection, entityId, field};
}

/// The winning HLC behind each reduced field — the LWW comparison input.
@DataClassName('FieldClockRow')
class FieldClocks extends Table {
  TextColumn get collection => text()();
  TextColumn get entityId => text()();
  TextColumn get field => text()();
  IntColumn get wallMs => integer()();
  IntColumn get counter => integer()();
  TextColumn get memberIdHex => text()();

  @override
  Set<Column<Object>> get primaryKey => {collection, entityId, field};
}

/// Entity deletions. A field whose clock is newer than the tombstone's is
/// visible again — resurrection falls out of comparing at read time rather than
/// deleting rows, which also makes reduction order-independent.
@DataClassName('RowTombstoneRow')
class RowTombstones extends Table {
  TextColumn get collection => text()();
  TextColumn get entityId => text()();
  IntColumn get wallMs => integer()();
  IntColumn get counter => integer()();
  TextColumn get memberIdHex => text()();

  @override
  Set<Column<Object>> get primaryKey => {collection, entityId};
}

/// The Root this device pinned for one `(workspace, user)` escrow slot.
///
/// Trust on first successful unwrap, against the *passphrase* and not against
/// the server (ADR-0028): once [rootPk] is here, an escrow record signed by
/// anything else is a server-integrity alarm rather than a prompt.
///
/// [highestEscrowVersionSeen] is a per-slot high-water mark, and the scoping is
/// load-bearing: one shared across workspaces would let a busy slot's version
/// numbers mask a rollback in a quiet one.
@DataClassName('RootPinRow')
class RootPins extends Table {
  TextColumn get workspaceId => text()();
  TextColumn get userId => text()();

  /// Raw 32-byte Ed25519 Root public key.
  BlobColumn get rootPk => blob()();
  IntColumn get highestEscrowVersionSeen => integer()();
  DateTimeColumn get pinnedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, userId};
}

/// The head of the cross-author control chain this device has *applied*.
///
/// [lastControlPayloadHash] is SHA-256 over the payload bytes of the last
/// control op that passed verification, which is what the next one must name.
/// [appliedCount] is what makes the zero-hash rule decidable: an all-zero
/// `prev_control_hash` is legal only while no control op has been applied, and
/// a zero hash arriving after that is a fork candidate, never a fresh start.
@DataClassName('ControlChainRow')
class ControlChainState extends Table {
  TextColumn get workspaceId => text()();
  BlobColumn get lastControlPayloadHash => blob()();
  IntColumn get appliedCount => integer()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId};
}

/// Every control op this device has **applied**, in seq order.
///
/// The recompute substrate for the grants view (#549). Grants and roles are
/// derived from these rows at read time rather than cached: control ops are few,
/// so there is nothing here worth a copy — and per the naming rule, a stored copy
/// would have to say so in its name and could then go stale. `controlChainState`
/// remains the fast head pointer over the same facts.
///
/// [certHlc] fields are the *certificate's* clock, not the op's: the fork
/// tie-break is "earliest cert HLC, then lowest author member id", and an op-level
/// clock would let a forking author move the tie by re-signing an envelope.
@TableIndex(name: 'applied_control_log_workspace', columns: {#workspaceId, #seq})
@DataClassName('AppliedControlRow')
class AppliedControlLog extends Table {
  TextColumn get workspaceId => text()();

  /// The server's transport cursor for this op. The authorization verdict is
  /// positional against these numbers, which is why they are stored.
  IntColumn get seq => integer()();

  /// One of `control_payload.dart`'s served control types.
  TextColumn get controlType => text()();

  /// The unframed payload bytes, kept verbatim so the chain link — SHA-256 over
  /// exactly these bytes — is recomputable rather than remembered.
  BlobColumn get payloadBytes => blob()();
  BlobColumn get payloadHash => blob()();

  /// What this op named as its predecessor. Two rows sharing one value are a
  /// fork, which is the whole detection rule.
  BlobColumn get prevControlHash => blob()();
  TextColumn get authorMemberId => text()();

  /// The certificate's own HLC, flattened for ordering: `wall_ms`, then
  /// `counter`. The tie-break's first key.
  IntColumn get certWallMs => integer()();
  IntColumn get certCounter => integer()();
  DateTimeColumn get appliedAt => dateTime()();

  /// Set when a fork resolution put this op on the losing branch. Rows are kept
  /// rather than deleted: the log is evidence, and a quarantined branch is
  /// something the user gets to inspect.
  DateTimeColumn get quarantinedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, seq};
}

/// The monotone `key_epoch` floor for one Workspace.
///
/// Raise-only, and consulted when **authoring**: a device refuses to build an
/// envelope below the floor, which is what makes a rotation stick rather than
/// being undone by the next offline write. Fixed at 0 by genesis; #554's verified
/// `rotate` control op is the only thing that will ever raise it in anger, and
/// until then the floor is exercised through the API and across restart.
///
/// Not named `cached_*` deliberately: this is not derived from anything. It is
/// the persisted high-water mark itself, and the raise-only API is its contract.
@DataClassName('EpochFloorRow')
class EpochFloors extends Table {
  TextColumn get workspaceId => text()();
  IntColumn get keyEpochFloor => integer()();
  DateTimeColumn get raisedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId};
}

@DriftDatabase(
  tables: [
    OpLog,
    Outbox,
    AuthorState,
    SyncCursors,
    QuarantinedOps,
    IntegrityAlarms,
    ReducedFields,
    FieldClocks,
    RowTombstones,
    RootPins,
    ControlChainState,
    AppliedControlLog,
    EpochFloors,
  ],
)
class SyncDatabase extends _$SyncDatabase {
  SyncDatabase(super.executor);

  /// v2 adds the pinned-Root and control-chain tables (#548); v3 adds
  /// `sync_cursors.last_sync_completed_at` (#550); v4 adds the integrity-alarm
  /// store, the quarantine and op-log columns the chain verdict needs, and the
  /// three indexes it reads through (#551); v5 adds the applied-control log the
  /// grants view is derived from and the per-Workspace `epoch_floor` (#549);
  /// v6 turns the documented integrity-alarm upsert key into a constraint.
  @override
  int get schemaVersion => 6;

  /// Additive only. A device that already holds a log keeps every byte of it:
  /// each step is `CREATE TABLE`s, an `ADD COLUMN` or a `CREATE INDEX`, and no
  /// data movement.
  ///
  /// The steps are sequential `if (from < n)` rather than exclusive branches so
  /// that a device upgrading straight from v1 runs all of them, in order.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) => migrator.createAll(),
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            await migrator.createTable(rootPins);
            await migrator.createTable(controlChainState);
          }
          if (from < 3) {
            await migrator.addColumn(syncCursors, syncCursors.lastSyncCompletedAt);
          }
          if (from < 4) {
            await migrator.createTable(integrityAlarms);
            await migrator.addColumn(quarantinedOps, quarantinedOps.authorMemberId);
            await migrator.addColumn(quarantinedOps, quarantinedOps.authorSeq);
            await migrator.addColumn(quarantinedOps, quarantinedOps.releasedAt);
            await migrator.addColumn(opLog, opLog.appliedAt);
            await migrator.addColumn(opLog, opLog.refusedReason);
            // Everything logged before v4 was logged *after* a successful
            // apply, so the backfill is exact rather than a guess: leaving
            // `applied_at` null would make every pre-existing row read as
            // "logged, never applied".
            await customStatement(
              'UPDATE op_log SET applied_at = received_at WHERE applied_at IS NULL',
            );
            // Before v4 nothing enforced one op per chain slot, so a server that
            // re-served one author position under two transport seqs left two
            // rows that were both legal under the `(workspace_id, seq)` primary
            // key. Creating the unique index on such a store throws, and because
            // the whole `onUpgrade` is one migration the store then fails to open
            // on every launch — with a bare SQLite message naming only the index.
            await _refuseDuplicateKeysBeforeUniqueIndex(
              table: 'op_log',
              keyColumns: const ['workspace_id', 'author_member_id', 'author_seq'],
              invariant: 'one op per (workspace, author, author_seq) chain slot',
              recovery: 'delete and recreate this sync store',
            );
            await migrator.create(opLogAuthorChain);
            await migrator.create(opLogAuthorOpId);
            await migrator.create(quarantinedOpsAuthorChain);
          }
          if (from < 5) {
            // Two new tables and one index. Nothing is backfilled: a device
            // upgrading here has applied no control op under the #549 rules, and
            // its `epoch_floor` is genuinely unset rather than zero-by-decree —
            // the raise-only API reads an absent row as the 0 floor genesis fixes.
            await migrator.createTable(appliedControlLog);
            await migrator.createTable(epochFloors);
            await migrator.create(appliedControlLogWorkspace);
          }
          if (from < 6) {
            // The alarm upsert key was documented from v4 and honoured only by
            // `_raiseAlarm`'s select-then-write, so a store carrying a duplicate
            // is possible even though no code path aims for one.
            await _refuseDuplicateKeysBeforeUniqueIndex(
              table: 'integrity_alarms',
              keyColumns: const ['workspace_id', 'kind', 'author_member_id'],
              invariant: 'one standing accusation per (workspace, kind, author)',
              recovery: 'delete and recreate this sync store',
            );
            await migrator.create(integrityAlarmsKey);
          }
        },
      );

  /// Fail the migration with the invariant and the recovery spelled out, rather
  /// than letting `CREATE UNIQUE INDEX` fail on rows that predate the rule.
  ///
  /// Failing loud is the deliberate choice over de-duplicating first. ADR-0026
  /// makes the received log *the client's* evidence, and evidence is not edited
  /// to make a schema change succeed — a `DELETE … GROUP BY` here would silently
  /// destroy the very second row that proves the server re-served a spent slot.
  /// The cost is bounded because no store the server has ever seen exists before
  /// the #553 cutover: stores ship empty, and the dev and harness stores that can
  /// hold pre-rule rows are disposable. So the honest answer is to name what is
  /// wrong and stop, not to quietly launder it.
  ///
  /// Rows with a null key column are skipped, matching SQLite's unique-index
  /// semantics — distinct NULLs are distinct there, so grouping them would refuse
  /// a store the index would have accepted.
  Future<void> _refuseDuplicateKeysBeforeUniqueIndex({
    required String table,
    required List<String> keyColumns,
    required String invariant,
    required String recovery,
  }) async {
    final quoted = [for (final column in keyColumns) '"$column"'];
    final notNull = quoted.map((column) => '$column IS NOT NULL').join(' AND ');
    final duplicateKeyRows = await customSelect(
      'SELECT COUNT(*) AS duplicate_key_count FROM ('
      'SELECT 1 FROM "$table" WHERE $notNull '
      'GROUP BY ${quoted.join(', ')} HAVING COUNT(*) > 1)',
    ).get();
    final duplicateKeyCount = duplicateKeyRows.first.read<int>('duplicate_key_count');
    if (duplicateKeyCount == 0) return;
    throw StateError(
      'sync store migration refused: "$table" holds $duplicateKeyCount key(s) '
      'with more than one row, violating the invariant this migration makes a '
      'constraint — $invariant. The rows are evidence and are not de-duplicated '
      'to let the migration through; to recover, $recovery.',
    );
  }
}
