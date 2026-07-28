/// The client-owned sync store.
///
/// ADR-0026 requires the received log to be *the client's*, immutable evidence:
/// per-author chains only make server truncation and rollback detectable if the
/// client keeps what it received. So [OpLog] holds full envelope bytes, and
/// #551's chain verification reads them back.
///
/// This database is deliberately separate from `lib/database/gtd_database.dart`
/// and shares nothing with it. The production app still runs on PowerSync until
/// the cutover in #553; wiring both paths together now would be exactly the
/// dual-write branching the Implementation stance forbids.
library;

import 'package:drift/drift.dart';

part 'sync_database.g.dart';

/// Every envelope this device has received, byte for byte, in arrival order.
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
  /// record of what it authored, and #551's chain verification compares them
  /// against what the server later serves back.
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

  @override
  Set<Column<Object>> get primaryKey => {workspaceId};
}

/// Ops that failed a fail-closed rule: never applied, always surfaced.
@DataClassName('QuarantineRow')
class QuarantinedOps extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get workspaceId => text()();
  IntColumn get seq => integer().nullable()();
  TextColumn get reason => text()();
  TextColumn get detail => text()();
  BlobColumn get envelope => blob()();
  DateTimeColumn get detectedAt => dateTime()();
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

@DriftDatabase(
  tables: [
    OpLog,
    Outbox,
    AuthorState,
    SyncCursors,
    QuarantinedOps,
    ReducedFields,
    FieldClocks,
    RowTombstones,
    RootPins,
    ControlChainState,
  ],
)
class SyncDatabase extends _$SyncDatabase {
  SyncDatabase(super.executor);

  @override
  int get schemaVersion => 2;

  /// Additive only. A device that already holds a log keeps every byte of it:
  /// v2 adds the pinned-Root and control-chain tables and touches nothing else,
  /// so an upgrade is two `CREATE TABLE`s and no data movement.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) => migrator.createAll(),
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            await migrator.createTable(rootPins);
            await migrator.createTable(controlChainState);
          }
        },
      );
}
