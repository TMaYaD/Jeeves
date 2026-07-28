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

  /// When the last pull completed, independent of flush state — the
  /// `SyncHealth.lastSyncedAt` source. Deliberately not "last successful sync":
  /// a wedged outbox is reported through `pendingOpCount`, never by withholding
  /// a timestamp that would make a receiving device look unreachable.
  DateTimeColumn get lastSyncCompletedAt => dateTime().nullable()();

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
  ],
)
class SyncDatabase extends _$SyncDatabase {
  SyncDatabase(super.executor);

  /// v2 adds `sync_cursors.last_sync_completed_at` (#550). #551's integrity
  /// tables are the next step; whichever slice merges second rebases its
  /// migration onto the other's version rather than sharing a step.
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(syncCursors, syncCursors.lastSyncCompletedAt);
          }
        },
      );
}
